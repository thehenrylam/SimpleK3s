# Pre-built Subsystems
# - Subsystems that help serve as the foundation of the cluster (Traefik, Kyverno, External Secrets, etc)
# - Even though these subsystems should be relatively light, they can impact resources under certain conditions (scaling, HA, etc)

# Input data (Typically used for the modules listed within this file)
locals {
    subsystems_default = {
        traefik             = {}
        kyverno             = {}
        external-secrets    = {}
        descheduler         = {}
    }
    subsystems = merge(local.subsystems_default, var.subsystems)

    s3_config_subsystems = {
        id      = aws_s3_bucket.bootstrap.id
        keyroot = local.s3_bstrap_key_root_default
    }
    iam_config_subsystems = {
        role_name   = aws_iam_role.irole_ec2.name
        partition   = data.aws_partition.current.partition
    }
}

# Output data (Typically used for modules outside the file)
locals {
    s3keys_default_subsystems = concat(
        try(module.cluster_app_traefik.processed_s3obj, []), # Traefik files
        try(module.cluster_app_kyverno.processed_s3obj, []), # Kyverno files
        [] # Default empty list (in case no submodules are initalized or commented out)
    )
}

module "cluster_app_traefik" {
    source      = "./cluster_app/traefik" 
    # General settings
    nickname    = var.nickname 
    settings    = local.subsystems.traefik 
    # S3 settings
    s3_config   = local.s3_config_subsystems
    # IAM settings 
    iam_config  = local.iam_config_subsystems
}

module "cluster_app_kyverno" {
    source      = "./cluster_app/kyverno" 
    # General settings
    nickname    = var.nickname 
    settings    = local.subsystems.kyverno 
    # S3 settings
    s3_config   = local.s3_config_subsystems
    # IAM settings 
    iam_config  = local.iam_config_subsystems
}

# module "cluster_app_external-secrets" {
#     source      = "./cluster_app/external-secrets" 
#     # General settings
#     nickname    = var.nickname 
#     settings    = var.subsystems.external-secrets 
#     # S3 settings
#     s3_config   = local.s3_config_subsystems
#     # IAM settings 
#     iam_config  = local.iam_config_subsystems
# }

# module "cluster_app_descheduler" {
#     source      = "./cluster_app/descheduler" 
#     # General settings
#     nickname    = var.nickname 
#     settings    = var.subsystems.descheduler 
#     # S3 settings
#     s3_config   = local.s3_config_subsystems
#     # IAM settings 
#     iam_config  = local.iam_config_subsystems
# }
