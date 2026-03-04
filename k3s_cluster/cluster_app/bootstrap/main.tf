locals {
    module_name = "cluster_app_${basename(path.module)}"

    default_settings = {
        version         = "???"
        nodeport_http   = 30080
        nodeport_https  = 30443
        ingress_http    = 80
    }

    settings = {
        version         = coalesce(try(var.settings.version,null),          local.default_settings.version)
        nodeport_http   = coalesce(try(var.settings.nodeport_http,null),    local.default_settings.nodeport_http)
        nodeport_https  = coalesce(try(var.settings.nodeport_https,null),   local.default_settings.nodeport_https)
        ingress_http    = coalesce(try(var.settings.ingress_http,null),     local.default_settings.ingress_http)
    }

    # Resource presets (to put into performance profiles)
    resource_presets = module.common.resource_presets
}

# Get common values (i.e. resource_presents)
module "common" {
    source      = "../utils/common_values"
}

# Set up the aws pstore
# module "aws_pstore" {
#     source      = "../utils/aws_pstore"
#     # General variables
#     nickname    = var.nickname
#     module_name = local.module_name
#     # IAM config
#     iam_config      = var.iam_config
#     # Parameter store data
#     pstore_data = [
#         {
#             alias       = "ip_config"
#             name        = local.settings.pstore_idp_config
#             encrypted   = true
#         }
#     ]
# }

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
            src         = "${path.module}/bootstrap/default/init.sh",
            template    = null
        },
        { # SimpleK3s Env Vars
            desc        = "SimpleK3s Env Vars",
            key         = "${var.s3_config.keyroot}/simplek3s.env",
            src         = "${path.module}/bootstrap/default/simplek3s.env", 
            template    = {
                bootstrap_dir           = local.bstrap_dir
                nickname                = var.nickname
                aws_region              = var.aws_region
                controller_host         = local.controller_host
                swapfile_alloc_amt      = var.ec2_swapfile_size
                nodeport_http           = var.k3s_nodeport_traefik_http
                nodeport_https          = var.k3s_nodeport_traefik_https
                pstore_key_root         = local.pstore_key_root
                s3_bucket_name          = local.s3_bstrap_name
            }
        },
        { # Common Functions
            desc        = "Common Functions",
            key         = "${var.s3_config.keyroot}/lib/common.sh",
            src         = "${path.module}/bootstrap/default/lib/common.sh",
            template    = null
        },
        { # Common Functions (AWS)
            desc        = "Common Functions (AWS)",
            key         = "${var.s3_config.keyroot}/lib/providers/aws.sh",
            src         = "${path.module}/bootstrap/default/lib/providers/aws.sh",
            template    = null
        },
        {
            desc        = "Init Script (Install Packages)",
            key         = "${var.s3_config.keyroot}/01_install_packages.sh",
            src         = "${path.module}/bootstrap/default/01_install_packages.sh",
            template    = null
        },
        {
            desc        = "Init Script (Setup Swapfile)",
            key         = "${var.s3_config.keyroot}/02_setup_swapfile.sh",
            src         = "${path.module}/bootstrap/default/02_setup_swapfile.sh",
            template    = null
        },
        {
            desc        = "Init Script (Install K3s)",
            key         = "${var.s3_config.keyroot}/03_install_k3s.sh",
            src         = "${path.module}/bootstrap/default/03_install_k3s.sh",
            template    = null
        }
    ]
}
