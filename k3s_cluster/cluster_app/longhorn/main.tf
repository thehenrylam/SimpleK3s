terraform {
  required_version = "~> 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

locals {
  module_name = "cluster_app_${basename(path.module)}"

  default_version = "1.12.0"

  settings = {
    version = coalesce(try(var.settings.version, null), local.default_version)
    pools = [for p in var.settings.pools : merge(p, {
      disk_path = coalesce(try(p.disk_path, null), "/mnt/longhorn-${p.name}")
    })]
  }

  any_backups_enabled = anytrue([for p in local.settings.pools : p.backup_s3_prefix != null])

  backup_target = (local.any_backups_enabled && var.backup_bucket_name != null
    ? "s3://${var.backup_bucket_name}@${var.aws_region}/"
    : ""
  )

  resource_presets = module.common.resource_presets
}

# Get common values (i.e. resource_presets)
module "common" {
  source = "../utils/common_values"
}

##############################################
#   Capacity Guardrail : SSM Data Sources    #
##############################################
data "aws_ssm_parameter" "pool_volumes" {
  for_each = { for p in local.settings.pools : p.name => p }
  name     = each.value.ebs_volumes_pstore_name
}

locals {
  pool_volume_ids = {
    for name, param in data.aws_ssm_parameter.pool_volumes :
    # nonsensitive: aws_ssm_parameter marks .value sensitive by default, but volume
    # IDs are resource identifiers, not secrets. Unwrap so they can be used as for_each keys.
    name => jsondecode(nonsensitive(param.value))
  }
  all_volume_ids = toset(flatten([for ids in values(local.pool_volume_ids) : ids]))
}

data "aws_ebs_volume" "pool_disks" {
  for_each = local.all_volume_ids
  filter {
    name   = "volume-id"
    values = [each.key]
  }
}

locals {
  pool_min_capacities = {
    for pool in local.settings.pools :
    pool.name => min([
      for vid in local.pool_volume_ids[pool.name] :
      data.aws_ebs_volume.pool_disks[vid].size
    ]...)
  }
}

##############################################
#   Capacity Guardrail : Precondition Check  #
##############################################
resource "terraform_data" "capacity_check" {
  for_each = var.app_pvc_requirements

  lifecycle {
    precondition {
      condition     = each.value <= lookup(local.pool_min_capacities, each.key, 0)
      error_message = "Pool '${each.key}': total declared PVC size ${each.value} GB exceeds the effective pool capacity ${lookup(local.pool_min_capacities, each.key, 0)} GB (limited by the smallest EBS volume in the pool). Reduce PVC sizes or provision larger EBS volumes."
    }
  }
}

##############################################
#   S3 Object Uploads                        #
##############################################
module "aws_s3obj" {
  source = "../utils/aws_s3obj"
  # General variables
  nickname    = var.nickname
  module_name = local.module_name
  # S3 settings
  s3_bucket_id = var.s3_config.id
  s3obj_data = [
    {
      desc = "Longhorn HelmChart + per-pool StorageClasses"
      key  = "${var.s3_config.keyroot}/manifests/longhorn.yaml"
      src  = "${path.module}/data/longhorn.yaml"
      template = jsonencode({
        version        = local.settings.version
        backup_enabled = local.any_backups_enabled && var.backup_bucket_name != null
        backup_target  = local.backup_target
        pools = [for p in local.settings.pools : {
          name           = p.name
          default        = p.default
          replica_count  = tostring(length(local.pool_volume_ids[p.name]))
          reclaim_policy = p.reclaim_policy
          data_locality  = p.data_locality
        }]
        cfg = local.performance_profile["standard"]
      })
    },
    {
      desc = "Longhorn pools config (consumed by per-node EBS attachment script)"
      key  = "${var.s3_config.keyroot}/longhorn_pools_config.json"
      src  = "${path.module}/data/longhorn_pools_config.json"
      template = jsonencode({
        pools = [for p in local.settings.pools : {
          name                    = p.name
          ebs_volumes_pstore_name = p.ebs_volumes_pstore_name
          disk_path               = p.disk_path
          node_target             = p.node_target
        }]
      })
    },
    {
      desc     = "Init Script (Apply Longhorn)"
      key      = "${var.s3_config.keyroot}/sub_apply_longhorn.sh"
      src      = "${path.module}/data/sub_apply_longhorn.sh"
      template = null
    }
  ]
}
