terraform {
  required_version = "~> 1.11"
}

locals {
  module_name = "cluster_app_${basename(path.module)}"

  default_settings = {
    version         = "v1.35.1+k3s1"
    env_vars        = jsonencode({})
    pstore_key_root = "/simplek3s/${var.nickname}"
  }

  settings = {
    version         = coalesce(try(var.settings.version, null), local.default_settings.version)
    env_vars        = coalesce(try(var.settings.env_vars, null), local.default_settings.env_vars)
    pstore_key_root = coalesce(try(var.settings.pstore_key_root, null), local.default_settings.pstore_key_root)
  }

}

# Get common values (i.e. resource_presents)
module "common" {
  source = "../utils/common_values"
}

# Set up the aws pstore
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
      alias     = "k3s_token"
      name      = "${local.settings.pstore_key_root}/k3s-token"
      desc      = "The K3s token - This is set on runtime"
      encrypted = true
      create    = true
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
    { # Default Installation (Main installation script — MUST remain first; Terraform
      # picks index [0] as the s3key_install_script passed to cloud-init)
      desc     = "Default Init Script",
      key      = "${var.s3_config.keyroot}/node_init-all.sh",
      src      = "${path.module}/data/node_init-all.sh",
      template = null
    },
    { # SimpleK3s Env Vars
      desc     = "SimpleK3s Env Vars",
      key      = "${var.s3_config.keyroot}/simplek3s.env",
      src      = "${path.module}/data/simplek3s.env",
      template = jsonencode(merge(jsondecode(local.settings.env_vars), { k3s_version = local.settings.version }))
    },
    { # Common Functions
      desc     = "Common Functions",
      key      = "${var.s3_config.keyroot}/lib/common.sh",
      src      = "${path.module}/data/lib/common.sh",
      template = null
    },
    { # Common Functions (AWS)
      desc     = "Common Functions (AWS)",
      key      = "${var.s3_config.keyroot}/lib/providers/aws.sh",
      src      = "${path.module}/data/lib/providers/aws.sh",
      template = null
    },
    {
      desc     = "Init Script (Install Packages)",
      key      = "${var.s3_config.keyroot}/bts_01_install_packages.sh",
      src      = "${path.module}/data/bts_01_install_packages.sh",
      template = null
    },
    {
      desc     = "Init Script (Setup Swapfile)",
      key      = "${var.s3_config.keyroot}/bts_02_setup_swapfile.sh",
      src      = "${path.module}/data/bts_02_setup_swapfile.sh",
      template = null
    },
    {
      desc     = "Init Script (Install K3s)",
      key      = "${var.s3_config.keyroot}/bts_03_install_k3s.sh",
      src      = "${path.module}/data/bts_03_install_k3s.sh",
      template = null
    },
    {
      desc     = "Init Script (Stage Manifests)",
      key      = "${var.s3_config.keyroot}/bts_05_stage_manifests.sh",
      src      = "${path.module}/data/bts_05_stage_manifests.sh",
      template = null
    },
    {
      desc     = "Init Script (Converge Actions)",
      key      = "${var.s3_config.keyroot}/converge_actions.sh",
      src      = "${path.module}/data/converge_actions.sh",
      template = null
    },
    {
      desc     = "Node Script (Refresh Bootstrap Files)",
      key      = "${var.s3_config.keyroot}/node_refresh-bootstrap-files.sh",
      src      = "${path.module}/data/node_refresh-bootstrap-files.sh",
      template = null
    },
    {
      desc     = "Node Script (Init Essential — node-local setup only)",
      key      = "${var.s3_config.keyroot}/node_init-essential.sh",
      src      = "${path.module}/data/node_init-essential.sh",
      template = null
    },
    {
      desc     = "Node Script (Init Services — stage manifests + converge)",
      key      = "${var.s3_config.keyroot}/node_init-services.sh",
      src      = "${path.module}/data/node_init-services.sh",
      template = null
    },
    {
      desc     = "Node Script (Verify All — cluster health check)",
      key      = "${var.s3_config.keyroot}/node_verify-all.sh",
      src      = "${path.module}/data/node_verify-all.sh",
      template = null
    },
    {
      desc     = "Helper Script (Python - pyproject.toml)"
      key      = "${var.s3_config.keyroot}/py/pyproject.toml",
      src      = "${path.module}/data/py/pyproject.toml",
      template = null
    },
    {
      desc     = "Helper Script (Python - .python-version)"
      key      = "${var.s3_config.keyroot}/py/.python-version",
      src      = "${path.module}/data/py/.python-version",
      template = null
    },
    {
      desc     = "Helper Script (Python - fetch_UTILITIES.py)"
      key      = "${var.s3_config.keyroot}/py/fetch_UTILITIES.py",
      src      = "${path.module}/data/py/fetch_UTILITIES.py",
      template = null
    },
    {
      desc     = "Helper Script (Python - fetch_hardware.py)"
      key      = "${var.s3_config.keyroot}/py/fetch_hardware.py",
      src      = "${path.module}/data/py/fetch_hardware.py",
      template = null
    },
    {
      desc     = "Helper Script (Python - fetch_k3s-platform.py)"
      key      = "${var.s3_config.keyroot}/py/fetch_k3s-platform.py",
      src      = "${path.module}/data/py/fetch_k3s-platform.py",
      template = null
    },
    {
      desc     = "Helper Script (Python - fetch_k3s-apps.py)"
      key      = "${var.s3_config.keyroot}/py/fetch_k3s-apps.py",
      src      = "${path.module}/data/py/fetch_k3s-apps.py",
      template = null
    },
    {
      desc     = "Helper Script (Python - fetch_app-external-secrets.py)"
      key      = "${var.s3_config.keyroot}/py/fetch_app-external-secrets.py",
      src      = "${path.module}/data/py/fetch_app-external-secrets.py",
      template = null
    },
    {
      desc     = "Helper Script (Python - fetch_app-longhorn.py)"
      key      = "${var.s3_config.keyroot}/py/fetch_app-longhorn.py",
      src      = "${path.module}/data/py/fetch_app-longhorn.py",
      template = null
    },
    {
      desc     = "Helper Script (Python - fetch_app-karpenter.py)"
      key      = "${var.s3_config.keyroot}/py/fetch_app-karpenter.py",
      src      = "${path.module}/data/py/fetch_app-karpenter.py",
      template = null
    },
    {
      desc     = "Helper Script (Python - fetch_app-kyverno.py)"
      key      = "${var.s3_config.keyroot}/py/fetch_app-kyverno.py",
      src      = "${path.module}/data/py/fetch_app-kyverno.py",
      template = null
    },
    {
      desc     = "Helper Script (Python - fetch_app-traefik.py)"
      key      = "${var.s3_config.keyroot}/py/fetch_app-traefik.py",
      src      = "${path.module}/data/py/fetch_app-traefik.py",
      template = null
    },
    {
      desc     = "Helper Script (Python - fetch_app-argocd.py)"
      key      = "${var.s3_config.keyroot}/py/fetch_app-argocd.py",
      src      = "${path.module}/data/py/fetch_app-argocd.py",
      template = null
    },
    {
      desc     = "Helper Script (Python - fetch_app-grafana.py)"
      key      = "${var.s3_config.keyroot}/py/fetch_app-grafana.py",
      src      = "${path.module}/data/py/fetch_app-grafana.py",
      template = null
    },
    {
      desc     = "Helper Script (Python - fetch_app-grafana-pvc.py)"
      key      = "${var.s3_config.keyroot}/py/fetch_app-grafana-pvc.py",
      src      = "${path.module}/data/py/fetch_app-grafana-pvc.py",
      template = null
    },
    {
      desc     = "Helper Script (Python - fetch_app-prometheus.py)"
      key      = "${var.s3_config.keyroot}/py/fetch_app-prometheus.py",
      src      = "${path.module}/data/py/fetch_app-prometheus.py",
      template = null
    },
    {
      desc     = "Helper Script (Python - fetch_app-prometheus-pvc.py)"
      key      = "${var.s3_config.keyroot}/py/fetch_app-prometheus-pvc.py",
      src      = "${path.module}/data/py/fetch_app-prometheus-pvc.py",
      template = null
    },
    {
      desc     = "Helper Script (Python - fetch_app-thanos.py)"
      key      = "${var.s3_config.keyroot}/py/fetch_app-thanos.py",
      src      = "${path.module}/data/py/fetch_app-thanos.py",
      template = null
    },
    {
      desc     = "Helper Script (Python - fetch_app-descheduler.py)"
      key      = "${var.s3_config.keyroot}/py/fetch_app-descheduler.py",
      src      = "${path.module}/data/py/fetch_app-descheduler.py",
      template = null
    },
    {
      desc     = "Helper Script (Python - fetch_app-tailscale.py)"
      key      = "${var.s3_config.keyroot}/py/fetch_app-tailscale.py",
      src      = "${path.module}/data/py/fetch_app-tailscale.py",
      template = null
    },
    {
      desc     = "Init Script (Setup Longhorn EBS Disks)",
      key      = "${var.s3_config.keyroot}/bts_04_setup_longhorn_diskpools.sh",
      src      = "${path.module}/data/bts_04_setup_longhorn_diskpools.sh",
      template = null
    }
  ]
}
