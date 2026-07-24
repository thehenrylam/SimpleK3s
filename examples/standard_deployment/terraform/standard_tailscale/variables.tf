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

# --- Read-only OAuth client (list + preflight Lambdas) ----------------------
# A SEPARATE Tailscale OAuth client from the operator one above, with only READ
# scopes (devices:read, acl:read, dns:read). Used by the list and preflight
# Lambdas so their tokens literally cannot delete anything (least privilege).
# See README.md for how to create it.
variable "tailscale_readonly_oauth_client_id" {
  description = "Read-only Tailscale OAuth client ID (devices:read, acl:read, dns:read). Separate from the operator client."
  type        = string
  sensitive   = true
}

variable "tailscale_readonly_oauth_client_secret" {
  description = "Read-only Tailscale OAuth client secret. Sensitive — used by the list/preflight Lambdas only."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.tailscale_readonly_oauth_client_secret) > 0
    error_message = "tailscale_readonly_oauth_client_secret must not be empty."
  }
}

# --- Lambda observability knobs (apply to all Tailscale Lambdas) ------------
# Shared by the cleanup, list, and preflight Lambdas.
# Minimal cost:  lambda_log_retention_days = 7,   lambda_enable_xray_tracing = false
# Full audit:    lambda_log_retention_days = 365, lambda_enable_xray_tracing = true

variable "lambda_log_retention_days" {
  description = "CloudWatch Logs retention (days) for the Tailscale Lambdas. Lower = cheaper; higher = longer audit trail. Must be a value CloudWatch accepts."
  type        = number
  default     = 180 # ~6 months (180 is the valid CloudWatch value; 185 is rejected by the API)

  validation {
    # CloudWatch Logs only accepts this fixed set of retention values (0 = never expire).
    condition = contains(
      [0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.lambda_log_retention_days
    )
    error_message = "lambda_log_retention_days must be a value CloudWatch Logs accepts: 0 (never expire), 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, or 3653."
  }
}

variable "lambda_enable_xray_tracing" {
  description = "Enable AWS X-Ray active tracing on the Tailscale Lambdas (adds X-Ray IAM permissions + marginal cost). Off by default to minimize cost; turn on for full traceability."
  type        = bool
  default     = false
}
