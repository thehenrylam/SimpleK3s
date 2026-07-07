terraform {
  required_version = "~> 1.11"
}

locals {
  module_name = "cluster_app_${basename(path.module)}"

  default_settings = {
    version = "1.98.4"
    tags    = ["tag:k8s"]
  }

  settings = {
    version         = coalesce(try(var.settings.version, null), local.default_settings.version)
    pstore_oauth    = var.settings.pstore_oauth
    tags            = coalesce(try(var.settings.tags, null), local.default_settings.tags)
    hostname_prefix = coalesce(try(var.settings.hostname_prefix, null), var.nickname)
  }

  # Resource presets (to put into performance profiles)
  resource_presets = module.common.resource_presets
}

# Get common values (i.e. resource_presets)
module "common" {
  source = "../utils/common_values"
}

# Set up the aws pstore (grants the EC2 role read access to the OAuth Parameter
# Store entry and resolves its region for the SecretStore)
module "aws_pstore" {
  source = "../utils/aws_pstore"
  # General variables
  nickname    = var.nickname
  module_name = local.module_name
  # IAM config
  iam_config = var.iam_config
  # Parameter store data
  pstore_data = [
    {
      alias     = "oauth"
      name      = local.settings.pstore_oauth
      desc      = "Tailscale operator OAuth client (client_id + client_secret)"
      encrypted = true
      create    = false # Set to false: SSM ParamStore provided by an outside source
    }
  ]
}

# Set up the aws s3obj
module "aws_s3obj" {
  source = "../utils/aws_s3obj"
  # General variables
  nickname    = var.nickname
  module_name = local.module_name
  # S3 settings
  s3_bucket_id = var.s3_config.id
  s3obj_data = [
    { # Tailscale Operator Manifests (HelmChart + SecretStore + ExternalSecret)
      desc = "Tailscale Operator Manifests",
      key  = "${var.s3_config.keyroot}/manifests/tailscale-helmchart.yaml",
      src  = "${path.module}/data/tailscale-helmchart.yaml",
      template = jsonencode({
        version         = local.settings.version
        region          = module.aws_pstore.processed_pstores[local.settings.pstore_oauth].region
        pstore_oauth    = local.settings.pstore_oauth
        proxy_tags      = join(",", local.settings.tags)
        hostname_prefix = local.settings.hostname_prefix
        resources       = local.resource_profile["standard"]
        # Single tailnet device fronting Traefik's tsnet entrypoint
        traefik_service   = var.traefik_backend.service
        traefik_namespace = var.traefik_backend.namespace
        traefik_port      = var.traefik_backend.port
      })
    },
    {
      desc     = "Init Script (Apply Tailscale)",
      key      = "${var.s3_config.keyroot}/sub_apply_tailscale.sh",
      src      = "${path.module}/data/sub_apply_tailscale.sh",
      template = null
    }
  ]
}
