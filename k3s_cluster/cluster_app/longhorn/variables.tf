variable "nickname" {
  description = "The nickname of the module"
  type        = string
}

variable "settings" {
  description = "The settings of the Longhorn subsystem"
  type = object({
    version = optional(string)
    pools = list(object({
      name                    = string
      default                 = optional(bool, false)
      ebs_volumes_pstore_name = string
      node_target             = optional(string, "controlplane")
      disk_path               = optional(string)
      reclaim_policy          = optional(string, "Retain")
      data_locality           = optional(string, "disabled")
      backup_s3_prefix        = optional(string)
    }))
  })
}

variable "s3_config" {
  description = "The S3 bucket config (Controls where the files will be uploaded in S3)"
  type = object({
    id      = string
    keyroot = string
  })
}

# map of pool_name → total GB of PVCs declared by built-in apps bound to that pool
variable "app_pvc_requirements" {
  description = "Per-pool PVC total (GB) from built-in apps, used for the capacity guardrail"
  type        = map(number)
  default     = {}
}

# Name of the dedicated Longhorn backup S3 bucket (null when backups are disabled)
variable "backup_bucket_name" {
  description = "Dedicated S3 bucket name for Longhorn backups (null = backups disabled)"
  type        = string
  default     = null
}

variable "aws_region" {
  description = "AWS region (needed to construct the Longhorn S3 backup target URL)"
  type        = string
}
