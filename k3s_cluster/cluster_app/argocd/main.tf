locals {
    module_name = "cluster_app_argocd"

    # Resource presets (to put into performance profiles)
    resource_presets = module.common.resource_presets

    performance_profile = {
        standard = {
            controller = {
                resources = {
                    req = local.resource_presets.med
                    lmt = local.resource_presets.xxl
                }
            }
            repoServer = {
                resources = {
                    req = local.resource_presets.med
                    lmt = local.resource_presets.xxl
                }
            }
            applicationSet = {
                resources = {
                    req = local.resource_presets.sml
                    lmt = local.resource_presets.lrg
                }
            }
            dex = {
                resources = {
                    req = local.resource_presets.tny
                    lmt = local.resource_presets.med
                }
            }
            redis = {
                resources = {
                    req = local.resource_presets.tny
                    lmt = local.resource_presets.lrg
                }
            }
            notifications = {
                resources = {
                    req = local.resource_presets.tny
                    lmt = local.resource_presets.lrg
                }
            }
            server = {
                resources = {
                    req = local.resource_presets.sml
                    lmt = local.resource_presets.xl
                }
            }
        }

    }
}

# Get common values (i.e. resource_presents)
module "common" {
    source      = "../utils/common_values"
}

# Set up the aws pstore
module "aws_pstore" {
    source      = "../utils/aws_pstore"

    nickname    = var.nickname
    module_name = local.module_name

    iam_config      = var.iam_config

    pstore_data = [
        {
            alias       = "ip_config"
            name        = var.settings.pstore_idp_config
            encrypted   = true
        }
    ]
}

# Set up the aws s3obj
module "aws_s3obj" {
    source      = "../utils/aws_s3obj"

    nickname    = var.nickname
    module_name = local.module_name

    s3_bucket_id    = var.s3_config.id 
    s3obj_data      = [
        {
            desc        = "ArgoCD config all-in-one (HelmChart, Secrets, ConfigMaps, etc)" 
            key         = "${var.s3_config.keyroot}/manifests/argocd.yaml" 
            src         = "${path.module}/data/argocd.yaml" 
            template    = jsonencode({
                domain_name         = var.settings.domain_name 
                pstore_idp_config   = var.settings.pstore_idp_config
                region_idp_config   = module.aws_pstore.processed_pstores[var.settings.pstore_idp_config].region
                cfg = local.performance_profile["standard"] # merge({}, local.performance_profile["standard"])
            })
        },
        {
            desc        = "ArgoCD installation script (to be executed by the Default Init Script)"
            key         = "${var.s3_config.keyroot}/optional_argocd.sh"
            src         = "${path.module}/data/optional_argocd.sh"
            template    = null
        }
    ]
}
