# Network/Resource Settings
aws_region = "us-east-1"

# DNS name
dns = {
  basename = "YOUR_DNS_NAME_HERE"
  prefix   = "k3s"
}

# Tailnet identity — set ONLY if any app uses exposure="internal".
# MUST match subsystems.tailscale in the cluster root (e.g. ex_basic):
#   hostname_prefix -> subsystems.tailscale.hostname_prefix (defaults to nickname)
#   magic_dns_name  -> subsystems.tailscale.magic_dns_name
# tailscale = {
#   hostname_prefix = "simplek3s"
#   magic_dns_name  = "YOUR-TAILNET.ts.net"
# }
