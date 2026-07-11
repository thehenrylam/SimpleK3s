# Copy this file to terraform.tfvars and fill in the values.
# terraform.tfvars is gitignored (it holds a secret) — never commit it.

aws_region = "us-east-1"
nickname   = "tailscale-standalone" # path becomes /tailscale-standalone/<nickname>/oauth_config

# Operator OAuth client (write). Docs: https://tailscale.com/docs/kubernetes-operator/install-operator
tailscale_oauth_client_id     = "REPLACE_WITH_TAILSCALE_OAUTH_CLIENT_ID"
tailscale_oauth_client_secret = "REPLACE_WITH_TAILSCALE_OAUTH_CLIENT_SECRET"

# Read-only OAuth client (SEPARATE from the operator one above) for the list +
# preflight Lambdas. Scopes: devices:read, acl:read, dns:read. See README.md.
tailscale_readonly_oauth_client_id     = "REPLACE_WITH_TAILSCALE_READONLY_OAUTH_CLIENT_ID"
tailscale_readonly_oauth_client_secret = "REPLACE_WITH_TAILSCALE_READONLY_OAUTH_CLIENT_SECRET"

# Configure this IF you want to utilize Internal-facing app setups (e.g. Only have ArgoCD/Grafana/Prometheus accessible via Tailscale and not let anybody else access it)
tailscale_magic_dns_name = "TAILSCALE_MAGIC_DNS_NAME" # Example: <tailscale-name>.ts.net

# Tailscale Lambda observability (optional — applies to cleanup/list/preflight).
#   Minimal cost:  lambda_log_retention_days = 7,   lambda_enable_xray_tracing = false
#   Full audit:    lambda_log_retention_days = 365, lambda_enable_xray_tracing = true
# lambda_log_retention_days  = 180   # CloudWatch value only (…, 90, 120, 150, 180, 365, …); default 180 (~6 months)
# lambda_enable_xray_tracing = false # default false
