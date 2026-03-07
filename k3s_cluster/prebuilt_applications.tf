# Pre-built Applications
# - Applications that enhances the capabilities of the cluster (deployer, monitoring, etc)
# - Some apps expected to use significant amount of resources, please plan accordingly

# Input data (Typically used for the modules listed within this file)
locals {
    applications_default = {
        argocd      = {}
        monitoring  = {}
    }
    applications = merge(local.applications_default, var.applications)

    s3_config_applications = {
        id      = aws_s3_bucket.bootstrap.id
        keyroot = local.s3_bstrap_key_root_default
    }
    iam_config_applications = {
        role_name   = aws_iam_role.irole_ec2.name
        partition   = data.aws_partition.current.partition
    }
}

# Output data (Typically used for modules outside the file)
locals {
    s3keys_default_applications = concat(
        try(module.cluster_app_argocd[0].processed_s3obj, []), # (Optional) ArgoCD files
        try(module.cluster_app_monitoring[0].processed_s3obj, []), # (Optional) Monitoring file
        [] # Default empty list (in case no submodules are initalized or commented out)
    )
}

# IF ENABLED: Check and Set up all of the needed files for ArgoCD 
# Handles:
#   - S3 object upload
#   - IAM rights settings (e.g. role name of the EC2 env to allow getting secret settings from the ParameterStore)
module "cluster_app_argocd" {
    count           = var.applications.argocd != null ? 1 : 0 
    source          = "./cluster_app/argocd" 
    # General settings
    nickname        = var.nickname 
    settings        = var.applications.argocd 
    # S3 settings
    s3_config       = local.s3_config_applications
    # IAM settings 
    iam_config      = local.iam_config_applications
}

# IF ENABLED: Check and Set up all of the needed files for Monitoring (Prometheus & Grafana) 
# Handles:
#   - S3 object upload
#   - IAM rights settings (e.g. role name of the EC2 env to allow getting secret settings from the ParameterStore)
module "cluster_app_monitoring" {
    count           = var.applications.monitoring != null ? 1 : 0 
    source          = "./cluster_app/monitoring" 
    # General settings
    nickname        = var.nickname 
    settings        = var.applications.monitoring 
    # S3 settings
    s3_config       = local.s3_config_applications
    # IAM settings 
    iam_config      = local.iam_config_applications
}
