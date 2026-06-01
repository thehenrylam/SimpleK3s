variable "nickname" {
  description = "The nickname of the module"
  type        = string
}

variable "settings" {
  description = "The settings of the argocd app"
  type = object({
    version = optional(string)
  })
}

variable "s3_config" {
  description = "The S3 bucket config (Controls where the files will be uploaded in S3)"
  type = object({
    id      = string
    keyroot = string
  })
}
