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
        { # Traefik Config (Template)
            desc        = "Traefik Config",
            key         = "${var.s3_config.keyroot}/manifests/traefik-config.yaml",
            src         = "${path.module}/data/traefik-config.yaml",
            template    = jsonencode({
                version         = local.settings.version
                network         = {
                    traefik = {
                        nodeport_http   = local.settings.nodeport_http
                        nodeport_https  = local.settings.nodeport_https
                    }
                }
                resources       = local.resource_profile["standard"]
            })
        },
        { # Traefik Middleware (Reroute Network Traffic from HTTP to HTTPs)
            desc        = "Traefik Middleware",
            key         = "${var.s3_config.keyroot}/manifests/traefik-middleware.yaml",
            src         = "${path.module}/data/traefik-middleware.yaml",
            template    = jsonencode({
                network = {
                    traefik = {
                        ingress_http    = local.settings.ingress_http
                    }
                }
            })
        },
        {
            desc        = "Init Script (Apply Traefik)",
            key         = "${var.s3_config.keyroot}/04_apply_traefik.sh",
            src         = "${path.module}/data/04_apply_traefik.sh",
            template    = null
        }
    ]
}
