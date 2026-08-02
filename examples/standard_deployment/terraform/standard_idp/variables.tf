variable "nickname" {
  description = "The nickname of the module"
  type        = string
  default     = "idp-standalone"
}

variable "aws_region" {
  description = "The aws region that the resources will deploy on (should be the same as used in the VPC)"
  type        = string
}

variable "dns" {
  description = "The DNS data that end-users will use to access the cluster (example.com)"
  type = object({
    basename = string
    prefix   = optional(string)
  })
}

# Tailnet identity used to register the internal (tailnet) OIDC callback/logout
# URLs. Set this only if any app in the cluster uses exposure="internal".
#
# CONTRACT: these MUST match the cluster root (e.g. examples/standard_deployment/terraform/standard_cluster):
#   hostname_prefix -> subsystems.tailscale.hostname_prefix (defaults to the
#                      cluster `nickname` when unset)
#   magic_dns_name  -> subsystems.tailscale.magic_dns_name
# ex_idp is a separate Terraform root, so this coupling cannot be validated in
# code — if the names drift, tailnet SSO breaks silently.
variable "tailscale" {
  description = "Tailnet identity (hostname_prefix + magic_dns_name) for internal OIDC URLs; must match subsystems.tailscale in the cluster root. Leave null if no app is internally exposed."
  type = object({
    hostname_prefix = string
    magic_dns_name  = string
  })
  default = null
}
