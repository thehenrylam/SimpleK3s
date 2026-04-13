locals {
    module_name = "cluster_app_${basename(path.module)}"

    default_settings = {
        version                 = "1.9.0"
        cluster_name            = var.nickname
        aws_region              = null
        controller_host         = null
        ami_id                  = null
        k3s_version             = "v1.35.1+k3s1"
        token_ssm_name          = "/simplek3s/${var.nickname}/k3s-token"
        subnet_ids              = []
        security_group_name     = null
        capacity_type           = "on-demand"
        arch                    = "arm64"
        instance_categories     = ["m", "c", "r"]
        instance_generation_gt  = 3
        cpu_limit               = "32"
        memory_limit            = "128Gi"
        consolidate_after       = "5m"
    }

    settings = {
        version                 = coalesce(try(var.settings.version, null),                local.default_settings.version)
        cluster_name            = coalesce(try(var.settings.cluster_name, null),           local.default_settings.cluster_name)
        aws_region              = coalesce(try(var.settings.aws_region, null),             local.default_settings.aws_region)
        controller_host         = coalesce(try(var.settings.controller_host, null),        local.default_settings.controller_host)
        ami_id                  = coalesce(try(var.settings.ami_id, null),                 local.default_settings.ami_id)
        k3s_version             = coalesce(try(var.settings.k3s_version, null),            local.default_settings.k3s_version)
        token_ssm_name          = coalesce(try(var.settings.token_ssm_name, null),         local.default_settings.token_ssm_name)
        subnet_ids              = coalesce(try(var.settings.subnet_ids, null),             local.default_settings.subnet_ids)
        security_group_name     = coalesce(try(var.settings.security_group_name, null),    local.default_settings.security_group_name)
        capacity_type           = coalesce(try(var.settings.capacity_type, null),          local.default_settings.capacity_type)
        arch                    = coalesce(try(var.settings.arch, null),                   local.default_settings.arch)
        instance_categories     = coalesce(try(var.settings.instance_categories, null),    local.default_settings.instance_categories)
        instance_generation_gt  = coalesce(try(var.settings.instance_generation_gt, null), local.default_settings.instance_generation_gt)
        cpu_limit               = coalesce(try(var.settings.cpu_limit, null),              local.default_settings.cpu_limit)
        memory_limit            = coalesce(try(var.settings.memory_limit, null),           local.default_settings.memory_limit)
        consolidate_after       = coalesce(try(var.settings.consolidate_after, null),      local.default_settings.consolidate_after)
    }

    resource_presets = module.common.resource_presets
}

module "common" {
    source = "../utils/common_values"
}

resource "terraform_data" "karpenter_settings_guard" {
    input = {
        ami_id              = local.settings.ami_id
        aws_region          = local.settings.aws_region
        controller_host     = local.settings.controller_host
        subnet_ids_len      = length(local.settings.subnet_ids)
        security_group_name = local.settings.security_group_name
    }

    lifecycle {
        precondition {
            condition     = local.settings.ami_id != null && local.settings.ami_id != ""
            error_message = "subsystems.karpenter.ami_id must be set."
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
            desc     = "Karpenter CRD HelmChart"
            key      = "${var.s3_config.keyroot}/manifests/karpenter-crd-helmchart.yaml"
            src      = "${path.module}/data/karpenter-crd-helmchart.yaml"
            template = jsonencode({
                version = local.settings.version
            })
        },
        {
            desc     = "Karpenter HelmChart"
            key      = "${var.s3_config.keyroot}/manifests/karpenter-helmchart.yaml"
            src      = "${path.module}/data/karpenter-helmchart.yaml"
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
            desc     = "Karpenter EC2NodeClass"
            key      = "${var.s3_config.keyroot}/manifests/karpenter-nodeclass.yaml"
            src      = "${path.module}/data/karpenter-nodeclass.yaml"
            template = jsonencode({
                cluster_name        = local.settings.cluster_name
                instance_profile    = aws_iam_instance_profile.karpenter_node.name # from iam.tf
                ami_id              = local.settings.ami_id
                aws_region          = local.settings.aws_region
                controller_host     = local.settings.controller_host
                k3s_version         = local.settings.k3s_version
                token_ssm_name      = local.settings.token_ssm_name
                subnet_ids          = local.settings.subnet_ids
                security_group_name = local.settings.security_group_name
                cloudinit_user_data = templatefile("${path.module}/../../cloudinit.sh.tftpl", {
                    count_index             = "0"
                    cluster_type            = "agentplane"
                    bootstrap_bucket        = var.s3_config.id
                    bootstrap_dir           = "/opt/simplek3s/" # TODO: Parameterize this
                    # Assume the first object of local.s3keys_default_bootstrap is the installation script
                    s3key_install_script    = "${var.s3_config.keyroot}/init.sh" # TODO: Parameterize this
                })
            })
        },
        {
            desc     = "Karpenter NodePool"
            key      = "${var.s3_config.keyroot}/manifests/karpenter-nodepool.yaml"
            src      = "${path.module}/data/karpenter-nodepool.yaml"
            template = jsonencode({
                cluster_name           = local.settings.cluster_name
                capacity_type          = local.settings.capacity_type
                arch                   = local.settings.arch
                instance_categories    = local.settings.instance_categories
                instance_generation_gt = local.settings.instance_generation_gt
                cpu_limit              = local.settings.cpu_limit
                memory_limit           = local.settings.memory_limit
                consolidate_after      = local.settings.consolidate_after
            })
        },
        {
            desc     = "Init Script (Apply Karpenter)"
            key      = "${var.s3_config.keyroot}/sub_apply_karpenter.sh"
            src      = "${path.module}/data/sub_apply_karpenter.sh"
            template = null
        }
    ]

    depends_on = [
        terraform_data.karpenter_settings_guard
    ]
}
