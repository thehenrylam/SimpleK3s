# Pre-built Applications
# - Applications that enhances the capabilities of the cluster (deployer, monitoring, etc)
# - Some apps expected to use significant amount of resources, please plan accordingly

# Input data (Typically used for the modules listed within this file)
locals {

  s3_config_applications = {
    id      = aws_s3_bucket.bootstrap.id
    keyroot = local.s3_bstrap_key_root_default
  }
  iam_config_applications = {
    role_name = aws_iam_role.irole_ec2.name
    partition = data.aws_partition.current.partition
  }
}

# Output data (Typically used for modules outside the file)
locals {
}

# Longhorn pool-reference validation (applications)
# Register here any APPLICATION that is wired to a Longhorn pool: "<ref-label>" => <pool_name>.
# The check below fails the plan when a referenced pool is not defined in
# subsystems.longhorn.pools. null entries are ignored (the app isn't using storage).
locals {
  longhorn_pool_refs_applications = {
    monitoring = local.monitoring_pool_name
  }
}

resource "terraform_data" "longhorn_pool_check_applications" {
  for_each = { for ref_label, pool_name in local.longhorn_pool_refs_applications : ref_label => pool_name if pool_name != null }

  lifecycle {
    precondition {
      condition     = contains(local.longhorn_pool_names, each.value)
      error_message = "Application '${each.key}' references Longhorn pool '${each.value}', which is not defined in subsystems.longhorn.pools (available pools: ${length(local.longhorn_pool_names) > 0 ? join(", ", local.longhorn_pool_names) : "none — is the Longhorn subsystem enabled?"})."
    }
  }
}

# IF ENABLED: Check and Set up all of the needed files for ArgoCD 
# Handles:
#   - S3 object upload
#   - IAM rights settings (e.g. role name of the EC2 env to allow getting secret settings from the ParameterStore)
module "cluster_app_argocd" {
  count  = var.applications.argocd != null ? 1 : 0
  source = "./cluster_app/argocd"
  # General settings
  nickname = var.nickname
  settings = var.applications.argocd
  # S3 settings
  s3_config = local.s3_config_applications
  # IAM settings
  iam_config = local.iam_config_applications
}

# IF ENABLED: Check and Set up all of the needed files for Monitoring (Prometheus & Grafana)
# Handles:
#   - S3 object upload
#   - IAM rights settings (e.g. role name of the EC2 env to allow getting secret settings from the ParameterStore)
module "cluster_app_monitoring" {
  count  = var.applications.monitoring != null ? 1 : 0
  source = "./cluster_app/monitoring"
  # General settings
  nickname   = var.nickname
  settings   = var.applications.monitoring
  aws_region = var.aws_region
  # S3 settings
  s3_config = local.s3_config_applications
  # IAM settings
  iam_config = local.iam_config_applications
  # Resolved Longhorn StorageClass (null when no storage block or Longhorn not enabled)
  storage_class_name = (
    try(var.applications.monitoring.storage, null) != null && local.monitoring_pool_name != null
    ? "longhorn-${local.monitoring_pool_name}"
    : null
  )
  # Thanos metrics bucket (always created when monitoring is enabled; see monitoring_thanos_s3.tf)
  thanos_bucket_name = try(aws_s3_bucket.thanos[0].bucket, null)
}
