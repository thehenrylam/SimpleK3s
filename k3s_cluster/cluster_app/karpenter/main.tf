terraform {
  required_version = "~> 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

locals {
  module_name = "cluster_app_${basename(path.module)}"

  default_settings = {
    version           = "1.9.0"
    cluster_name      = var.nickname
    aws_region        = null
    controller_host   = null
    ami_id            = null
    root_volume_size  = 24
    k3s_version       = "v1.35.1+k3s1"
    aws_cli_version   = "2.34.63"
    ssm_agent_version = "3.3.4515.0"
    # No default on purpose: the root must supply the key the bootstrap module
    # actually uploaded. A default here would be a second place naming the file,
    # which is exactly how it drifted before.
    s3key_install_script   = null
    token_ssm_name         = "/simplek3s/${var.nickname}/k3s-token"
    subnet_ids             = []
    security_group_name    = null
    capacity_type          = "on-demand"
    arch                   = "arm64"
    instance_categories    = ["m", "c", "r"]
    instance_generation_gt = 3
    # Node size envelope (#131). Defaults describe a t4g.medium..t4g.xlarge
    # window: big enough to carry the DaemonSet tax plus real work, small enough
    # that a t4g.2xlarge (8 vCPU / 32 GiB) cannot appear unprompted. Set any of
    # these to null to leave that end of the range open.
    min_instance_cpu        = 2     # 1-vCPU types cannot carry their own baseline
    max_instance_cpu        = 4     # excludes t4g.2xlarge (8 vCPU)
    min_instance_memory_mib = 4096  # t4g.medium
    max_instance_memory_mib = 16384 # t4g.xlarge; excludes 2xlarge (32768)
    # Aggregate ceiling. memory_limit is an exact spend cap for t4g: $/mo = GiB x $6.132.
    # node_limit is intentionally unset — see the `limits:` comment in the template.
    node_limit        = null
    cpu_limit         = "16"
    memory_limit      = "64Gi"
    consolidate_after = "5m"
  }

  settings = {
    version                = coalesce(try(var.settings.version, null), local.default_settings.version)
    cluster_name           = coalesce(try(var.settings.cluster_name, null), local.default_settings.cluster_name)
    aws_region             = coalesce(try(var.settings.aws_region, null), local.default_settings.aws_region)
    controller_host        = coalesce(try(var.settings.controller_host, null), local.default_settings.controller_host)
    ami_id                 = coalesce(try(var.settings.ami_id, null), local.default_settings.ami_id)
    root_volume_size       = coalesce(try(var.settings.root_volume_size, null), local.default_settings.root_volume_size)
    k3s_version            = coalesce(try(var.settings.k3s_version, null), local.default_settings.k3s_version)
    aws_cli_version        = coalesce(try(var.settings.aws_cli_version, null), local.default_settings.aws_cli_version)
    ssm_agent_version      = coalesce(try(var.settings.ssm_agent_version, null), local.default_settings.ssm_agent_version)
    s3key_install_script   = coalesce(try(var.settings.s3key_install_script, null), local.default_settings.s3key_install_script)
    token_ssm_name         = coalesce(try(var.settings.token_ssm_name, null), local.default_settings.token_ssm_name)
    subnet_ids             = coalesce(try(var.settings.subnet_ids, null), local.default_settings.subnet_ids)
    security_group_name    = coalesce(try(var.settings.security_group_name, null), local.default_settings.security_group_name)
    capacity_type          = coalesce(try(var.settings.capacity_type, null), local.default_settings.capacity_type)
    arch                   = coalesce(try(var.settings.arch, null), local.default_settings.arch)
    instance_categories    = coalesce(try(var.settings.instance_categories, null), local.default_settings.instance_categories)
    instance_generation_gt = coalesce(try(var.settings.instance_generation_gt, null), local.default_settings.instance_generation_gt)
    # Optional bounds: "" tells the template to omit the stanza entirely, so a
    # caller can open an end of the range. coalesce() cannot express this — it
    # treats "" as absent and would fall back to the default — hence the explicit
    # null checks.
    min_instance_cpu        = try(var.settings.min_instance_cpu, null) != null ? tostring(var.settings.min_instance_cpu) : (local.default_settings.min_instance_cpu == null ? "" : tostring(local.default_settings.min_instance_cpu))
    max_instance_cpu        = try(var.settings.max_instance_cpu, null) != null ? tostring(var.settings.max_instance_cpu) : (local.default_settings.max_instance_cpu == null ? "" : tostring(local.default_settings.max_instance_cpu))
    min_instance_memory_mib = try(var.settings.min_instance_memory_mib, null) != null ? tostring(var.settings.min_instance_memory_mib) : (local.default_settings.min_instance_memory_mib == null ? "" : tostring(local.default_settings.min_instance_memory_mib))
    max_instance_memory_mib = try(var.settings.max_instance_memory_mib, null) != null ? tostring(var.settings.max_instance_memory_mib) : (local.default_settings.max_instance_memory_mib == null ? "" : tostring(local.default_settings.max_instance_memory_mib))
    node_limit              = try(var.settings.node_limit, null) != null ? tostring(var.settings.node_limit) : (local.default_settings.node_limit == null ? "" : tostring(local.default_settings.node_limit))
    cpu_limit               = coalesce(try(var.settings.cpu_limit, null), local.default_settings.cpu_limit)
    memory_limit            = coalesce(try(var.settings.memory_limit, null), local.default_settings.memory_limit)
    consolidate_after       = coalesce(try(var.settings.consolidate_after, null), local.default_settings.consolidate_after)
  }

}

module "common" {
  source = "../utils/common_values"
}

resource "terraform_data" "karpenter_settings_guard" {
  input = {
    ami_id               = local.settings.ami_id
    aws_region           = local.settings.aws_region
    controller_host      = local.settings.controller_host
    subnet_ids_len       = length(local.settings.subnet_ids)
    security_group_name  = local.settings.security_group_name
    s3key_install_script = local.settings.s3key_install_script
  }

  lifecycle {
    precondition {
      condition     = local.settings.ami_id != null && local.settings.ami_id != ""
      error_message = "subsystems.karpenter.ami_id must be set."
    }

    # A wrong value here does not fail the apply — it fails silently at node boot,
    # where cloud-init cannot find the script and the node never registers. Karpenter
    # then reaps and relaunches on a loop, so there is no error surface to notice.
    precondition {
      condition     = local.settings.s3key_install_script != null && local.settings.s3key_install_script != ""
      error_message = "subsystems.karpenter.s3key_install_script must be set (pass the bootstrap module's s3key_install_script output)."
    }

    precondition {
      condition     = local.settings.aws_region != null && local.settings.aws_region != ""
      error_message = "subsystems.karpenter.aws_region must be set."
    }

    precondition {
      condition     = local.settings.controller_host != null && local.settings.controller_host != ""
      error_message = "subsystems.karpenter.controller_host must be set."
    }

    precondition {
      condition     = length(local.settings.subnet_ids) > 0
      error_message = "subsystems.karpenter.subnet_ids must contain at least one subnet id."
    }

    precondition {
      condition     = local.settings.security_group_name != null && local.settings.security_group_name != ""
      error_message = "subsystems.karpenter.security_group_name must be set."
    }
  }
}

module "aws_s3obj" {
  source = "../utils/aws_s3obj"

  nickname    = var.nickname
  module_name = local.module_name

  s3_bucket_id = var.s3_config.id

  s3obj_data = [
    {
      desc = "Karpenter CRD HelmChart"
      key  = "${var.s3_config.keyroot}/manifests/karpenter-crd-helmchart.yaml"
      src  = "${path.module}/data/karpenter-crd-helmchart.yaml"
      template = jsonencode({
        version = local.settings.version
      })
    },
    {
      desc = "Karpenter HelmChart"
      key  = "${var.s3_config.keyroot}/manifests/karpenter-helmchart.yaml"
      src  = "${path.module}/data/karpenter-helmchart.yaml"
      template = jsonencode({
        version   = local.settings.version
        resources = local.resource_profile["standard"]
        settings = {
          cluster_name     = local.settings.cluster_name
          cluster_endpoint = "https://${local.settings.controller_host}:6443"
        }
      })
    },
    {
      desc = "Karpenter EC2NodeClass"
      key  = "${var.s3_config.keyroot}/manifests/karpenter-nodeclass.yaml"
      src  = "${path.module}/data/karpenter-nodeclass.yaml"
      template = jsonencode({
        cluster_name        = local.settings.cluster_name
        instance_profile    = aws_iam_instance_profile.karpenter_node.name # from iam.tf
        ami_id              = local.settings.ami_id
        root_volume_size    = local.settings.root_volume_size
        aws_region          = local.settings.aws_region
        controller_host     = local.settings.controller_host
        k3s_version         = local.settings.k3s_version
        token_ssm_name      = local.settings.token_ssm_name
        subnet_ids          = local.settings.subnet_ids
        security_group_name = local.settings.security_group_name
        cloudinit_user_data = templatefile("${path.module}/../../cloudinit.sh.tftpl", {
          count_index          = "0"
          cluster_type         = "agentplane"
          bootstrap_bucket     = var.s3_config.id
          bootstrap_dir        = "/opt/simplek3s/" # TODO: Parameterize this
          aws_cli_version      = local.settings.aws_cli_version
          ssm_agent_version    = local.settings.ssm_agent_version
          s3key_install_script = local.settings.s3key_install_script
        })
      })
    },
    {
      desc = "Karpenter NodePool"
      key  = "${var.s3_config.keyroot}/manifests/karpenter-nodepool.yaml"
      src  = "${path.module}/data/karpenter-nodepool.yaml"
      template = jsonencode({
        cluster_name            = local.settings.cluster_name
        capacity_type           = local.settings.capacity_type
        arch                    = local.settings.arch
        instance_categories     = local.settings.instance_categories
        instance_generation_gt  = local.settings.instance_generation_gt
        min_instance_cpu        = local.settings.min_instance_cpu
        max_instance_cpu        = local.settings.max_instance_cpu
        min_instance_memory_mib = local.settings.min_instance_memory_mib
        max_instance_memory_mib = local.settings.max_instance_memory_mib
        node_limit              = local.settings.node_limit
        cpu_limit               = local.settings.cpu_limit
        memory_limit            = local.settings.memory_limit
        consolidate_after       = local.settings.consolidate_after
      })
    },
  ]

  depends_on = [
    terraform_data.karpenter_settings_guard
  ]
}
