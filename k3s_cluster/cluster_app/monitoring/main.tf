locals {
    module_name = "cluster_app_${basename(path.module)}"

    settings = {
        version             = coalesce(try(var.settings.version, null), "0.1.0-alpha.0")
        pstore_idp_config   = var.settings.pstore_idp_config
        domain_name         = var.settings.domain_name
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
            alias       = "ip_config"
            name        = local.settings.pstore_idp_config
            desc        = "The IDP Config - Enables SSO for the underling app"
            encrypted   = true
            create      = false # Set to false: SSM ParamStore provided by an outside source
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
        {
            desc        = "Monitoring (Prometheus & Grafana) config all-in-one (HelmChart, Secrets, ConfigMaps, etc)" 
            key         = "${var.s3_config.keyroot}/manifests/monitoring.yaml" 
            src         = "${path.module}/data/monitoring.yaml" 
            template    = jsonencode({
                version             = local.settings.version
                domain_name         = local.settings.domain_name 
                pstore_idp_config   = local.settings.pstore_idp_config
                region_idp_config   = module.aws_pstore.processed_pstores[local.settings.pstore_idp_config].region
                cfg = merge({}, local.performance_profile["standard"])
            })
        },
        {
            desc        = "Monitoring (Prometheus & Grafana) installation script (to be executed by the Default Init Script)"
            key         = "${var.s3_config.keyroot}/app_monitoring.sh"
            src         = "${path.module}/data/app_monitoring.sh"
            template    = null
        }
    ]
}
