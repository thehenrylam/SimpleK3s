# Pre-built Subsystems
# - Subsystems that help serve as the foundation of the cluster (Traefik, Kyverno, External Secrets, etc)
# - Even though these subsystems should be relatively light, they can impact resources under certain conditions (scaling, HA, etc)

# Input data (Typically used for the modules listed within this file)
locals {
  subsystems_default = {
    traefik          = {}
    kyverno          = {}
    external-secrets = {}
    descheduler      = {}
    karpenter = {
      ami_id      = try(local.agentplane.ec2_ami_id, null)
      k3s_version = var.k3s_version
    }
  }
  subsystems = merge(local.subsystems_default, var.subsystems)

  s3_config_subsystems = {
    id      = aws_s3_bucket.bootstrap.id
    keyroot = local.s3_bstrap_key_root_default
  }
  iam_config_subsystems = {
    role_name  = aws_iam_role.irole_ec2.name
    partition  = data.aws_partition.current.partition
    region     = var.aws_region
    account_id = local.account_id
  }
}

# Output data (Typically used for modules outside the file)
locals {
  # Resolve which Longhorn pool each application will use (defaults to the pool marked default=true)
  longhorn_default_pool_name = try(
    one([for p in var.subsystems.longhorn.pools : p.name if p.default]),
    null
  )

  monitoring_pool_name = try(
    coalesce(var.applications.monitoring.storage.pool_name, local.longhorn_default_pool_name),
    null
  )

  # Sum PVC sizes per pool for the capacity guardrail
  longhorn_app_pvc_requirements = {
    for pool_name in toset(compact([local.monitoring_pool_name])) :
    pool_name => sum(compact([
      local.monitoring_pool_name == pool_name ? try(var.applications.monitoring.storage.components.grafana.pvc_size, 0) : null,
      local.monitoring_pool_name == pool_name ? try(var.applications.monitoring.storage.components.prometheus.pvc_size, 0) : null,
      local.monitoring_pool_name == pool_name ? try(var.applications.monitoring.storage.components.alertmanager.pvc_size, 0) : null,
    ]))
  }
}

module "cluster_app_traefik" {
  source = "./cluster_app/traefik"
  # General settings
  nickname = var.nickname
  settings = local.subsystems.traefik
  # S3 settings
  s3_config = local.s3_config_subsystems
}

module "cluster_app_kyverno" {
  source = "./cluster_app/kyverno"
  # General settings
  nickname = var.nickname
  settings = local.subsystems.kyverno
  # S3 settings
  s3_config = local.s3_config_subsystems
}

module "cluster_app_external-secrets" {
  source = "./cluster_app/external-secrets"
  # General settings
  nickname = var.nickname
  settings = local.subsystems.external-secrets
  # S3 settings
  s3_config = local.s3_config_subsystems
}

module "cluster_app_karpenter" {
  source = "./cluster_app/karpenter"
  # General settings
  nickname = var.nickname
  settings = merge(
    local.subsystems.karpenter,
    {
      cluster_name        = var.nickname
      aws_region          = var.aws_region
      controller_host     = local.controller_private_ip
      token_ssm_name      = "${local.pstore_key_root}/k3s-token"
      subnet_ids          = var.subnet_ids
      security_group_name = local.sg_ec2_name
      ami_id              = coalesce(try(local.subsystems.karpenter.ami_id, null), local.subsystems_default.karpenter.ami_id)
      k3s_version         = coalesce(try(local.subsystems.karpenter.k3s_version, null), local.subsystems_default.karpenter.k3s_version)
      aws_cli_version     = var.aws_cli_version
      ssm_agent_version   = var.ssm_agent_version
    }
  )
  # S3 settings
  s3_config = local.s3_config_subsystems
  # IAM settings
  iam_config = local.iam_config_subsystems
}

module "cluster_app_descheduler" {
  source = "./cluster_app/descheduler"
  # General settings
  nickname = var.nickname
  settings = local.subsystems.descheduler
  # S3 settings
  s3_config = local.s3_config_subsystems
}

module "cluster_app_longhorn" {
  count  = var.subsystems.longhorn != null ? 1 : 0
  source = "./cluster_app/longhorn"
  # General settings
  nickname = var.nickname
  settings = var.subsystems.longhorn
  # S3 settings
  s3_config = local.s3_config_subsystems
  # Capacity guardrail: PVC totals per pool from built-in apps
  app_pvc_requirements = local.longhorn_app_pvc_requirements
  # Backup bucket (null when backups are disabled for all pools)
  backup_bucket_name = try(aws_s3_bucket.longhorn_backup[0].bucket, null)
  # AWS region (for S3 backup target URL)
  aws_region = var.aws_region
}
