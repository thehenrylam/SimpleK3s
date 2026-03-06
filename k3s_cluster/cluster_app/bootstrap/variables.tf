variable "nickname" {
    description = "The nickname of the module"
    type        = string
}

variable "settings" {
    description = "The settings of the argocd app"
    type        = object({
        version             = optional(string)
        env_vars            = optional(string)
        pstore_key_root     = optional(string)
    })
}

# Optional: IAM config (to help refine IAM settings)
variable "iam_config" {
    description = "The config of the iam (to help refine IAM settings)"
    type        = object({
        role_name   = string
        partition   = optional(string)
        region      = optional(string)
        account_id  = optional(string)
    })
}

variable "s3_config" {
    description = "The S3 bucket config (Controls where the files will be uploaded in S3)"
    type        = object({
        id      = string 
        keyroot = string 
    })
}
