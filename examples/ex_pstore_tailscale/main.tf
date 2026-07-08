# OpenTofu / Terraform : SimpleK3s Tailscale OAuth (SSM Parameter Store)
#
# Writes the Tailscale Kubernetes Operator's OAuth client (client id + secret)
# into a single SecureString SSM parameter, in the JSON shape the cluster's
# tailscale subsystem expects:
#
#   { "client_id": "...", "client_secret": "..." }
#
# Deploy this root BEFORE the cluster (examples/ex_basic/) when you want any app
# exposed on the tailnet (exposure = "internal"). Paste the output parameter name
# into subsystems.tailscale.pstore_oauth in examples/ex_basic.
#
# ⚠️  DEMONSTRATION ONLY — this passes credentials through Terraform, which the
# project otherwise avoids. The secret lands in your tfvars AND in Terraform
# state in plaintext. See README.md for the why and for safer alternatives.

terraform {
  required_version = "~> 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# SecureString SSM parameter holding the operator OAuth client as JSON.
# Path convention: /tailscale-standalone/{nickname}/oauth_config
# `encrypted = true` on the cluster side reads this with decryption, so it must
# be a SecureString. Uses the default `aws/ssm` KMS key (see README for using a
# customer-managed key instead).
resource "aws_ssm_parameter" "tailscale_oauth" {
  name        = "/tailscale-standalone/${var.nickname}/oauth_config"
  description = "Tailscale operator OAuth client (client_id + client_secret)"
  type        = "SecureString"
  value = jsonencode({
    client_id     = var.tailscale_oauth_client_id
    client_secret = var.tailscale_oauth_client_secret
  })

  tags = {
    Nickname = var.nickname
  }
}

# SecureString SSM parameter holding the operator OAuth client as JSON.
# Path convention: /tailscale-standalone/{nickname}/dns_name
# This is just here to elegantly package the dns_name to be used in ex_basic (so that we have a consistent variable name to work off of)
# In addition, it helps better enforce separation of concerns (This module focuses everything about tailscale)
resource "aws_ssm_parameter" "tailscale_dns_name" {
  name        = "/tailscale-standalone/${var.nickname}/magic_dns_name"
  description = "Tailscale Magic DNS name"
  type        = "String"
  value = jsonencode({
    magic_dns_name = var.tailscale_magic_dns_name
  })

  tags = {
    Nickname = var.nickname
  }
}

