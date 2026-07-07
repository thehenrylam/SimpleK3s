variable "nickname" {
  description = "Standalone nickname for this parameter root (referenced from examples/ex_basic via pstore_oauth)"
  type        = string
  default     = "tailscale-standalone"
}

variable "aws_region" {
  description = "AWS region to create the SSM parameter in (must match the cluster region)"
  type        = string
}

variable "tailscale_oauth_client_id" {
  description = "Tailscale OAuth client ID (from the Tailscale admin console). NOT secret, but kept alongside the secret for a single bundled parameter."
  type        = string
  sensitive   = true
}

variable "tailscale_oauth_client_secret" {
  description = "Tailscale OAuth client secret (from the Tailscale admin console). Sensitive — see README.md."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.tailscale_oauth_client_secret) > 0
    error_message = "tailscale_oauth_client_secret must not be empty."
  }
}

variable "tailscale_magic_dns_name" {
  description = "Tailscale Magic DNS Name. This is here as a way to have ex_basic have a structured way to retrieve this value"
  type        = string

  validation {
    condition     = length(var.tailscale_magic_dns_name) > 0
    error_message = "tailscale_magic_dns_name must not be empty."
  }
}
