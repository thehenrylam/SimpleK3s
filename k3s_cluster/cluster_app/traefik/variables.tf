variable "nickname" {
  description = "The nickname of the module"
  type        = string
}

variable "settings" {
  description = "The settings of the argocd app"
  type = object({
    version        = optional(string)
    nodeport_http  = optional(number)
    nodeport_https = optional(number)
    ingress_http   = optional(number)
    # Dedicated plaintext entrypoint for tailnet traffic (fronted by a single
    # Tailscale device). Only rendered when Tailscale is enabled; TLS is
    # terminated by Tailscale, so this entrypoint stays plaintext and carries no
    # HTTP->HTTPS redirect. Not reachable via the public NLB (SG-gated).
    tsnet_enabled = optional(bool, false)
    tsnet_port    = optional(number, 8090)
  })
}

variable "s3_config" {
  description = "The S3 bucket config (Controls where the files will be uploaded in S3)"
  type = object({
    id      = string
    keyroot = string
  })
}
