# OpenTofu / Terraform : SimpleK3s PVC (EBS Volumes for Longhorn)
#
# Deploy this root BEFORE the cluster (examples/ex_basic/).
# It creates the EBS volumes that Longhorn attaches at node bootstrap time and
# writes their IDs to SSM so the cluster can discover them without hard-coding
# volume IDs in your cluster configuration.
#
# On tofu destroy of the cluster these volumes (and their data) survive.
# On tofu apply of the cluster, nodes re-attach the same volumes and Longhorn
# picks up where it left off.

terraform {
  required_version = "~> 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  # Flatten pools × AZs into a keyed map suitable for for_each
  volume_entries = merge([
    for pool in var.pools : {
      for az in pool.availability_zones :
      "${pool.name}-${az}" => {
        pool_name  = pool.name
        az         = az
        size       = pool.volume_size_gb
        iops       = pool.iops
        throughput = pool.throughput
      }
    }
  ]...)

  # Group the created volume IDs back per pool name, in AZ order
  pool_volume_ids = {
    for pool in var.pools : pool.name => [
      for az in pool.availability_zones :
      aws_ebs_volume.pool_disk["${pool.name}-${az}"].id
    ]
  }
}

resource "aws_ebs_volume" "pool_disk" {
  for_each = local.volume_entries

  availability_zone = each.value.az
  size              = each.value.size
  type              = "gp3"
  iops              = each.value.iops
  throughput        = each.value.throughput
  encrypted         = true

  tags = {
    Name     = "pvc-${var.nickname}-${each.value.pool_name}-${each.value.az}"
    Nickname = var.nickname
    Pool     = each.value.pool_name
  }
}

# One SSM parameter per pool — JSON array of volume IDs in AZ order.
# Path convention: /pvc-standalone/{nickname}/pvc_pool_{pool_name}
# The cluster reads this at bootstrap time and at tofu plan time (capacity guardrail).
resource "aws_ssm_parameter" "pool_volumes" {
  for_each = { for pool in var.pools : pool.name => pool }

  name  = "/pvc-standalone/${var.nickname}/pvc_pool_${each.key}"
  type  = "String"
  value = jsonencode(local.pool_volume_ids[each.key])

  tags = {
    Nickname = var.nickname
    Pool     = each.key
  }
}
