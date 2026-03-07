locals {
    module_name = "cluster_app_${basename(path.module)}"

    default_settings = {
        version                             = "3.7.1"
        control_plane_only                  = true
        control_plane_toleration_ns_list    = [
            "kyverno",
            "external-secrets",
            "argocd",
            "monitoring",
            "jenkins"
        ]
    }

    settings = {
        version             = coalesce(try(var.settings.version,null),              local.default_settings.version)
        control_plane_only  = coalesce(try(var.settings.control_plane_only,null),   local.default_settings.control_plane_only)
        control_plane_toleration_ns_list = coalesce(try(var.settings.control_plane_toleration_ns_list,null), local.default_settings.control_plane_toleration_ns_list)
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
        { # Kyverno Manifests
            desc        = "Kyverno Manifests",
            key         = "${var.s3_config.keyroot}/manifests/kyverno.yaml",
            src         = "${path.module}/data/kyverno.yaml",
            template    = jsonencode({
                chart_version       = local.settings.version
                control_plane_only  = local.settings.control_plane_only
                resources           = local.resource_profile["standard"]
            })
        },
        { # Kyverno (baseline-policies) Manifests
            desc        = "Kyverno (baseline-policies) Manifests",
            key         = "${var.s3_config.keyroot}/manifests/kyverno-baseline-policies.yaml",
            src         = "${path.module}/data/kyverno-baseline-policies.yaml",
            template    = jsonencode({
                control_plane_toleration_namespace_list = join("\n", [for ns in local.settings.control_plane_toleration_ns_list : "                - ${ns}"])
            })
        },
        {
            desc        = "Init Script (Apply Kyverno)",
            key         = "${var.s3_config.keyroot}/sub_apply_kyverno.sh",
            src         = "${path.module}/data/sub_apply_kyverno.sh",
            template    = null
        }
    ]
}
