variable "nickname" {
  description = "The nickname of the module"
  type        = string
}

variable "settings" {
  description = "The settings of the monitoring app"
  type = object({
    version           = optional(string)
    pstore_idp_config = string
    domain_name       = string
    storage = optional(object({
      pool_name = optional(string)
      components = optional(object({
        grafana      = optional(object({ pvc_size = optional(number, 5) }), { pvc_size = 5 })
        prometheus   = optional(object({ pvc_size = optional(number, 20) }), { pvc_size = 20 })
        alertmanager = optional(object({ pvc_size = optional(number, 2) }), { pvc_size = 2 })
      }), { grafana = { pvc_size = 5 }, prometheus = { pvc_size = 20 }, alertmanager = { pvc_size = 2 } })
    }))
  })
}

variable "storage_class_name" {
  description = "Resolved Longhorn StorageClass name for this application (null = no storage)"
  type        = string
  default     = null
}

# Optional: IAM config (to help refine IAM settings)
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
