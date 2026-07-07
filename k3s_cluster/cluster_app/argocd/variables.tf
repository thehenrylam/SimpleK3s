variable "nickname" {
  description = "The nickname of the module"
  type        = string
}

variable "settings" {
  description = "The settings of the argocd app"
  type = object({
    version           = optional(string)
    pstore_idp_config = string
    domain_name       = string
    # "external" = public LB via Traefik | "internal" = tailnet via Tailscale
    exposure = optional(string, "internal")
  })
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

# Tailnet identity — used to build the internal base URL when exposure="internal".
# internal_host_prefix defaults to the cluster nickname upstream; magic_dns_name is
# the tailnet domain (e.g. "opossum-copperhead.ts.net"), required for internal.
variable "internal_host_prefix" {
  description = "MagicDNS host prefix for the internal Tailscale Ingress (device short name is \"<prefix>-argocd\")"
  type        = string
  default     = null
}

variable "magic_dns_name" {
  description = "Tailnet MagicDNS domain used to build the internal base URL (required when exposure=\"internal\")"
  type        = string
  default     = null
}
