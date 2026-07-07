# Copy this file to terraform.tfvars and fill in the values.
# terraform.tfvars is gitignored (it holds a secret) — never commit it.

aws_region = "us-east-1"
nickname   = "tailscale-standalone" # path becomes /tailscale-standalone/<nickname>/oauth_config

# Related docs: https://tailscale.com/docs/kubernetes-operator/install-operator
tailscale_oauth_client_id     = "REPLACE_WITH_TAILSCALE_OAUTH_CLIENT_ID"
tailscale_oauth_client_secret = "REPLACE_WITH_TAILSCALE_OAUTH_CLIENT_SECRET"

# Configure this IF you want to utilize Internal-facing app setups (e.g. Only have ArgoCD/Grafana/Prometheus accessible via Tailscale and not let anybody else access it)
tailscale_magic_dns_name = "TAILSCALE_MAGIC_DNS_NAME" # Example: <tailscale-name>.ts.net
