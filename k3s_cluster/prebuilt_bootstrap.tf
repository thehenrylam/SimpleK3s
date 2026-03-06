# ####################################
# #  LOCALS : S3 Bootstrap : Files   #
# ####################################
locals {
    bootstrap_default = {
        bootstrap   = {}
    }
    # Enable this when there are meaningful configs to adjust bootstrap behavior
    # bootstrap = merge(local.bootstrap_default, var.bootstrap)

    s3_config_bootstrap = {
        id      = aws_s3_bucket.bootstrap.id
        keyroot = local.s3_bstrap_key_root_default
    }
    iam_config_bootstrap = {
        role_name   = aws_iam_role.irole_ec2.name
        partition   = data.aws_partition.current.partition
    }
}

# Output data (Typically used for modules outside the file)
locals {
    s3keys_default_bootstrap = concat(
        try(module.cluster_app_bootstrap.processed_s3obj, []), # Bootstrap files
        [] # Default empty list (in case no submodules are initalized or commented out)
    )
}

module "cluster_app_bootstrap" {
    source      = "./cluster_app/bootstrap" 
    # General settings
    nickname    = var.nickname 
    settings    = {
        pstore_key_root = local.pstore_key_root 
        env_vars        = jsonencode({
            bootstrap_dir       = local.bstrap_dir
            nickname            = var.nickname
            aws_region          = var.aws_region
            controller_host     = local.controller_host
            swapfile_alloc_amt  = var.ec2_swapfile_size
            nodeport_http       = var.k3s_nodeport_traefik_http
            nodeport_https      = var.k3s_nodeport_traefik_https
            pstore_key_root     = local.pstore_key_root
            s3_bucket_name      = local.s3_bstrap_name
        })
    }
    # S3 settings
    s3_config   = local.s3_config_bootstrap
    # IAM settings 
    iam_config  = local.iam_config_bootstrap
}
