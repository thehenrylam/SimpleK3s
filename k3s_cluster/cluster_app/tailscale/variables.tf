variable "nickname" {
  description = "The nickname of the module"
  type        = string
}

variable "settings" {
  description = "The settings of the tailscale subsystem"
  type = object({
    version = optional(string)
    # AWS Parameter Store entry (provided externally) holding the operator OAuth
    # client as JSON: { "client_id": "...", "client_secret": "..." }
    pstore_oauth    = string
    tags            = optional(list(string), ["tag:k8s"])
    hostname_prefix = optional(string)
  })
}

# IAM config (to grant the EC2 role read access to the OAuth Parameter Store entry)
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

# Traefik backend fronted by the single tailnet device. One Tailscale Ingress
# terminates TLS and forwards plaintext HTTP to Traefik's dedicated tsnet
# entrypoint; Traefik then host-scoped/path-routes to the internally-exposed apps.
variable "traefik_backend" {
  description = "The Traefik Service (name/namespace/port = tsnet entrypoint) the tailnet device fronts"
  type = object({
    service   = string
    namespace = string
    port      = number
  })
}
