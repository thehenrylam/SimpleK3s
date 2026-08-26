variable "nickname" {
  description = "The nickname of the module"
  type        = string
}

variable "settings" {
  description = "The settings of the karpenter subsystem"
  type = object({
    version         = optional(string)
    cluster_name    = optional(string)
    aws_region      = optional(string)
    controller_host = optional(string)
    ami_id          = optional(string)
    # Root volume size (GiB) for Karpenter-provisioned nodes. Must suit the largest
    # instance the NodePool may pick — blockDeviceMappings cannot vary by instance
    # type. See issue #124.
    root_volume_size  = optional(number)
    k3s_version       = optional(string)
    aws_cli_version   = optional(string)
    ssm_agent_version = optional(string)
    # S3 key of the bootstrap entry point run by a provisioned node's cloud-init.
    # Supplied by the root from the bootstrap module's own output rather than
    # rebuilt here — a literal in this module is what let it drift out of sync
    # with the object actually uploaded (see #121).
    s3key_install_script   = optional(string)
    token_ssm_name         = optional(string)
    subnet_ids             = optional(list(string))
    security_group_name    = optional(string)
    capacity_type          = optional(string)
    arch                   = optional(string)
    instance_categories    = optional(list(string))
    instance_generation_gt = optional(number)
    # Node size envelope — bounds the shape of ONE node. Omit either end to
    # leave it open.
    min_instance_cpu        = optional(number)
    max_instance_cpu        = optional(number)
    min_instance_memory_mib = optional(number)
    max_instance_memory_mib = optional(number)
    # Aggregate ceiling for the pool. node_limit caps node COUNT and is unset
    # by default; cpu/memory are the standing backstop.
    node_limit        = optional(string)
    cpu_limit         = optional(string)
    memory_limit      = optional(string)
    consolidate_after = optional(string)
  })
}

variable "iam_config" {
  description = "The config of the iam (to help refine IAM settings)"
  type = object({
    role_name  = string
    partition  = optional(string)
    region     = optional(string)
    account_id = optional(string)
  })
}

variable "s3_config" {
  description = "The S3 bucket config (Controls where the files will be uploaded in S3)"
  type = object({
    id      = string
    keyroot = string
  })
}
