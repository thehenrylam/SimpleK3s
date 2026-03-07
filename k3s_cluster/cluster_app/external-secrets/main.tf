locals {
    module_name = "cluster_app_${basename(path.module)}"

    default_settings = {
        version = "2.0.1"
    }

    settings = {
        version = coalesce(try(var.settings.version,null), local.default_settings.version)
    }

    # Resource presets (to put into performance profiles)
    resource_presets = module.common.resource_presets
}

# Get common values (i.e. resource_presents)
module "common" {
    source      = "../utils/common_values"
}

# # Set up the aws pstore
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
#             desc        = "The IDP Config - Enables SSO for the underling app"
#             encrypted   = true
#             create      = false # Set to false: SSM ParamStore provided by an outside source
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
        { # External Secrets Manifests
            desc        = "External Secrets Manifests",
            key         = "${var.s3_config.keyroot}/manifests/external-secrets.yaml",
            src         = "${path.module}/data/external-secrets.yaml",
            template    = jsonencode({
                version   = local.settings.version
                resources       = local.resource_profile["standard"]
            })
        },
        {
            desc        = "Init Script (Apply External Secrets)",
            key         = "${var.s3_config.keyroot}/05_apply_external-secrets.sh",
            src         = "${path.module}/data/05_apply_external-secrets.sh",
            template    = null
        }
    ]
}
