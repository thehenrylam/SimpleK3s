# ####################################
# #  LOCALS : S3 Bootstrap : Files   #
# ####################################
# locals {
#     # Bootstrapping : Data
#     # Key bootstrapping values
#     bstrap_dir                  = "/opt/simplek3s/"
#     # Filepaths for S3
#     s3_bstrap_key_root          = "bootstrap" # This is used as part of a key
#     s3_bstrap_key_root_default  = "${local.s3_bstrap_key_root}/default"
#     s3_bstrap_key_root_custom   = "${local.s3_bstrap_key_root}/custom"

#     # IMPORTANT: Main installation script (i.e. what we use to kick off node installation) MUST be the FIRST item
#     s3obj_data   = [
#         { # Default Installation (Main installation script)
#             desc        = "Default Init Script",
#             key         = "${local.s3_bstrap_key_root_default}/init.sh",
#             src         = "${path.module}/bootstrap/default/init.sh",
#             template    = null
#         },
#         { # SimpleK3s Env Vars
#             desc        = "SimpleK3s Env Vars",
#             key         = "${local.s3_bstrap_key_root_default}/simplek3s.env",
#             src         = "${path.module}/bootstrap/default/simplek3s.env", 
#             template    = {
#                 bootstrap_dir           = local.bstrap_dir
#                 nickname                = var.nickname
#                 aws_region              = var.aws_region
#                 controller_host         = local.controller_host
#                 swapfile_alloc_amt      = var.ec2_swapfile_size
#                 nodeport_http           = var.k3s_nodeport_traefik_http
#                 nodeport_https          = var.k3s_nodeport_traefik_https
#                 pstore_key_root         = local.pstore_key_root
#                 s3_bucket_name          = local.s3_bstrap_name
#             }
#         },
#         { # Common Functions
#             desc        = "Common Functions",
#             key         = "${local.s3_bstrap_key_root_default}/lib/common.sh",
#             src         = "${path.module}/bootstrap/default/lib/common.sh",
#             template    = null
#         },
#         { # Common Functions (AWS)
#             desc        = "Common Functions (AWS)",
#             key         = "${local.s3_bstrap_key_root_default}/lib/providers/aws.sh",
#             src         = "${path.module}/bootstrap/default/lib/providers/aws.sh",
#             template    = null
#         },
#         {
#             desc        = "Init Script (Install Packages)",
#             key         = "${local.s3_bstrap_key_root_default}/01_install_packages.sh",
#             src         = "${path.module}/bootstrap/default/01_install_packages.sh",
#             template    = null
#         },
#         {
#             desc        = "Init Script (Setup Swapfile)",
#             key         = "${local.s3_bstrap_key_root_default}/02_setup_swapfile.sh",
#             src         = "${path.module}/bootstrap/default/02_setup_swapfile.sh",
#             template    = null
#         },
#         {
#             desc        = "Init Script (Install K3s)",
#             key         = "${local.s3_bstrap_key_root_default}/03_install_k3s.sh",
#             src         = "${path.module}/bootstrap/default/03_install_k3s.sh",
#             template    = null
#         }
#     ]
# }

# # Output data (Typically used for modules outside the file)
# locals {
#     s3keys_default_bootstrap = concat(
#         try(module.cluster_app_bootstrap.processed_s3obj, []), # Bootstrap files
#         [] # Default empty list (in case no submodules are initalized or commented out)
#     )
# }

# module "cluster_app_bootstrap" {
#     source      = "./cluster_app/bootstrap" 
#     # General settings
#     nickname    = var.nickname 
#     settings    = {
#         env_vars = {
#             bootstrap_dir       = local.bstrap_dir
#             nickname            = var.nickname
#             aws_region          = var.aws_region
#             controller_host     = local.controller_host
#             swapfile_alloc_amt  = var.ec2_swapfile_size
#             nodeport_http       = var.k3s_nodeport_traefik_http
#             nodeport_https      = var.k3s_nodeport_traefik_https
#             pstore_key_root     = local.pstore_key_root
#             s3_bucket_name      = local.s3_bstrap_name
#         }
#     }
#     # S3 settings
#     s3_config   = local.s3_config_bootstrap
#     # IAM settings 
#     iam_config  = local.iam_config_bootstrap
# }
