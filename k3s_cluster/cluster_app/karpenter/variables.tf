variable "nickname" {
    description = "The nickname of the module"
    type        = string
}

variable "settings" {
    description = "The settings of the karpenter subsystem"
    type = object({
        version                = optional(string)
        cluster_name           = optional(string)
        aws_region             = optional(string)
        controller_host        = optional(string)
        ami_id                 = optional(string)
        k3s_version            = optional(string)
        token_ssm_name         = optional(string)
        subnet_ids             = optional(list(string))
        security_group_name    = optional(string)
        capacity_type          = optional(string)
        arch                   = optional(string)
        instance_categories    = optional(list(string))
        instance_generation_gt = optional(number)
        cpu_limit              = optional(string)
        memory_limit           = optional(string)
        consolidate_after      = optional(string)
        ssh_public_key         = optional(string)
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