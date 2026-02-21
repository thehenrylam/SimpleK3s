variable "nickname" {
    description = "The nickname of the module"
    type        = string
}

variable "settings" {
    description = "The settings of the argocd app"
    type        = object({
        idp_ssm_pstore_names    = object({
            idp_config = string
        })
        domain_name             = string
    })
}

variable "iam_role_name" {
    description = "The IAM role name (A role to attach additional policies to)"
    type        = string
}

# Optional: IAM config (to help refine IAM settings)
variable "iam_config" {
    description = "The config of the iam (to help refine IAM settings)"
    type        = object({
        partition   = optional(string)
        region      = optional(string)
        account_id  = optional(string)
    })
    default     = {
        partition   = "*"
        region      = "*"
        account_id  = "*"
    }
}

variable "s3_bucket_id" {
    description = "The S3 bucket id"
    type        = string
}

variable "s3obj_data" {
    description = "The S3 object data"
    type        = list(object({
        desc        = string
        key         = string
        src         = string
        template    = optional(string)
    }))
    default     = []
}
