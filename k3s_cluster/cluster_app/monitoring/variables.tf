variable "nickname" {
  description = "The nickname of the module"
  type        = string
}

variable "aws_region" {
  description = "AWS region (used to build the Thanos S3 endpoint)"
  type        = string
}

variable "thanos_bucket_name" {
  description = "S3 bucket name backing Thanos long-term metrics storage"
  type        = string
  default     = null
}

variable "settings" {
  description = "The settings of the monitoring app"
  type = object({
    version           = optional(string)
    pstore_idp_config = string
    domain_name       = string
    # "external" = public LB via Traefik | "internal" = tailnet via Tailscale
    exposure        = optional(string, "internal")
    scrape_interval = optional(string) # Prometheus global scrape cadence (default 60s)
    retention       = optional(string) # Time-based retention window (default 67d)
    storage = optional(object({
      pool_name = optional(string)
      components = optional(object({
        grafana      = optional(object({ pvc_size = optional(number, 5) }), { pvc_size = 5 })
        prometheus   = optional(object({ pvc_size = optional(number, 8) }), { pvc_size = 8 })
        alertmanager = optional(object({ pvc_size = optional(number, 2) }), { pvc_size = 2 })
      }), { grafana = { pvc_size = 5 }, prometheus = { pvc_size = 8 }, alertmanager = { pvc_size = 2 } })
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

# Tailnet identity — used to build the internal base URLs when exposure="internal".
# internal_host_prefix defaults to the cluster nickname upstream; magic_dns_name is
# the tailnet domain (e.g. "opossum-copperhead.ts.net"), required for internal.
variable "internal_host_prefix" {
  description = "MagicDNS host prefix for the internal Tailscale Ingresses (device short names are \"<prefix>-grafana\" / \"<prefix>-prometheus\")"
  type        = string
  default     = null
}

variable "magic_dns_name" {
  description = "Tailnet MagicDNS domain used to build the internal base URLs (required when exposure=\"internal\")"
  type        = string
  default     = null
}
