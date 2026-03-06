locals {
    module_name = "cluster_app_${basename(path.module)}"

    default_settings = {
        version         = "???"
        env_vars        = jsonencode({})
        pstore_key_root = "/simplek3s/${var.nickname}"
    }

    settings = {
        version         = coalesce(try(var.settings.version,null), local.default_settings.version)
        env_vars        = coalesce(try(var.settings.env_vars,null), local.default_settings.env_vars)
        pstore_key_root = coalesce(try(var.settings.pstore_key_root,null), local.default_settings.pstore_key_root)
    }

    # Resource presets (to put into performance profiles)
    resource_presets = module.common.resource_presets
}

# Get common values (i.e. resource_presents)
module "common" {
    source      = "../utils/common_values"
}

# Set up the aws pstore
module "aws_pstore" {
    source      = "../utils/aws_pstore"
    # General variables
    nickname    = var.nickname
    module_name = local.module_name
    # IAM config
    iam_config      = var.iam_config
    # Parameter store data
    pstore_data = [
        {
            alias       = "k3s_token"
            name        = "${local.settings.pstore_key_root}/k3s-token"
            desc        = "The K3s token - This is set on runtime"
            encrypted   = true
            create      = true
        }
    ]
}

# Set up the aws s3obj
module "aws_s3obj" {
    source      = "../utils/aws_s3obj"
    # General variables
    nickname    = var.nickname
    module_name = local.module_name
    # S3 settings
    s3_bucket_id    = var.s3_config.id 
    s3obj_data      = [
        { # Default Installation (Main installation script)
            desc        = "Default Init Script",
            key         = "${var.s3_config.keyroot}/init.sh",
            src         = "${path.module}/data/init.sh",
            template    = null
        },
        { # SimpleK3s Env Vars
            desc        = "SimpleK3s Env Vars",
            key         = "${var.s3_config.keyroot}/simplek3s.env",
            src         = "${path.module}/data/simplek3s.env", 
            template    = local.settings.env_vars
        },
        { # Common Functions
            desc        = "Common Functions",
            key         = "${var.s3_config.keyroot}/lib/common.sh",
            src         = "${path.module}/data/lib/common.sh",
            template    = null
        },
        { # Common Functions (AWS)
            desc        = "Common Functions (AWS)",
            key         = "${var.s3_config.keyroot}/lib/providers/aws.sh",
            src         = "${path.module}/data/lib/providers/aws.sh",
            template    = null
        },
        {
            desc        = "Init Script (Install Packages)",
            key         = "${var.s3_config.keyroot}/01_install_packages.sh",
            src         = "${path.module}/data/01_install_packages.sh",
            template    = null
        },
        {
            desc        = "Init Script (Setup Swapfile)",
            key         = "${var.s3_config.keyroot}/02_setup_swapfile.sh",
            src         = "${path.module}/data/02_setup_swapfile.sh",
            template    = null
        },
        {
            desc        = "Init Script (Install K3s)",
            key         = "${var.s3_config.keyroot}/03_install_k3s.sh",
            src         = "${path.module}/data/03_install_k3s.sh",
            template    = null
        }
    ]
}
