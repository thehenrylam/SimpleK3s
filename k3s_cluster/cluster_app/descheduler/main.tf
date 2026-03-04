locals {
    module_name = "cluster_app_traefik"

    default_settings = {
        version = "???"
        schedule    = "*/5 * * * *"
        policies    = {
            evict_local_storage_pods    = false
            ignore_pvc_pods             = true # false - Ignore PVC (persistent volume claim) pods can make it less likely for disruptions to occur
            evict_system_critical_pods  = false
        }
        thresholds  = {
            under_utilization_cpu   = "30"
            under_utilization_mem   = "40"
            target_utilization_cpu  = "60"
            target_utilization_mem  = "70"
        }
    }

    settings = {
        version     = coalesce(try(var.settings.version,null), local.default_settings.version)
        schedule    = coalesce(try(var.settings.schedule,null), local.default_settings.schedule)
        policies    = {
            evict_local_storage_pods    = coalesce(try(var.settings.policies.evict_local_storage_pods, null), local.default_settings.policies.evict_local_storage_pods)
            ignore_pvc_pods             = coalesce(try(var.settings.policies.ignore_pvc_pods, null), local.default_settings.policies.ignore_pvc_pods)
            evict_system_critical_pods  = coalesce(try(var.settings.policies.evict_system_critical_pods, null), local.default_settings.policies.evict_system_critical_pods)
        }
        thresholds  = {
            under_utilization_cpu   = coalesce(try(var.settings.thresholds.under_utilization_cpu,null), local.default_settings.thresholds.under_utilization_cpu)
            under_utilization_mem   = coalesce(try(var.settings.thresholds.under_utilization_mem,null), local.default_settings.thresholds.under_utilization_mem)
            target_utilization_cpu  = coalesce(try(var.settings.thresholds.target_utilization_cpu,null), local.default_settings.thresholds.target_utilization_cpu)
            target_utilization_mem  = coalesce(try(var.settings.thresholds.target_utilization_mem,null), local.default_settings.thresholds.target_utilization_mem)
        }
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
        { # Descheduler Manifests
            desc        = "Descheduler Manifests",
            key         = "${var.s3_config.keyroot}/manifests/descheduler.yaml",
            src         = "${path.module}/data/descheduler.yaml",
            template    = jsonencode({
                schedule    = local.settings.schedule
                policies    = local.settings.policies
                thresholds  = local.settings.thresholds
            })
        },
        {
            desc        = "Init Script (Apply Descheduler)",
            key         = "${var.s3_config.keyroot}/05_apply_descheduler.sh",
            src         = "${path.module}/data/05_apply_descheduler.sh",
            template    = null
        }
    ]
}
