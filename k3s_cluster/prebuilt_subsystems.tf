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
        karpenter           = {
            ami_id      = try(local.agentplane.ec2_ami_id, null)
            k3s_version = "v1.35.1+k3s1"
        }
    }
    subsystems = merge(local.subsystems_default, var.subsystems)

    s3_config_subsystems = {
        id      = aws_s3_bucket.bootstrap.id
        keyroot = local.s3_bstrap_key_root_default
    }
    iam_config_subsystems = {
        role_name   = aws_iam_role.irole_ec2.name
        partition   = data.aws_partition.current.partition
        region      = var.aws_region
        account_id  = local.account_id
    }
}

# Output data (Typically used for modules outside the file)
locals {
    s3keys_default_subsystems = concat(
        try(module.cluster_app_traefik.processed_s3obj, []), # Traefik files
        try(module.cluster_app_kyverno.processed_s3obj, []), # Kyverno files
        try(module.cluster_app_external-secrets.processed_s3obj, []), # External Secret files
        try(module.cluster_app_descheduler.processed_s3obj, []), # Descheduler files
        try(module.cluster_app_karpenter.processed_s3obj, []), # Karpenter files
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

module "cluster_app_external-secrets" {
    source      = "./cluster_app/external-secrets" 
    # General settings
    nickname    = var.nickname 
    settings    = local.subsystems.external-secrets 
    # S3 settings
    s3_config   = local.s3_config_subsystems
    # IAM settings 
    iam_config  = local.iam_config_subsystems
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
        }
    )
    # S3 settings
    s3_config  = local.s3_config_subsystems
    # IAM settings
    iam_config = local.iam_config_subsystems
}

module "cluster_app_descheduler" {
    source      = "./cluster_app/descheduler" 
    # General settings
    nickname    = var.nickname 
    settings    = local.subsystems.descheduler 
    # S3 settings
    s3_config   = local.s3_config_subsystems
    # IAM settings 
    iam_config  = local.iam_config_subsystems
}
