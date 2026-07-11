# OpenTofu / Terraform : IdP (Identification Provider) Standalone

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

locals {
  dns_basename = var.dns.basename
  dns_prefix   = coalesce(var.dns.prefix, "k3s")

  domain_name = "${local.dns_prefix}.${local.dns_basename}"

  default_callback_urls = [
    "https://${local.domain_name}/argocd/auth/callback",
    "https://${local.domain_name}/jenkins/securityRealm/finishLogin",
    "https://${local.domain_name}/grafana/login/generic_oauth",
    "https://${local.domain_name}/oauth2/oauth2/callback",
  ]

  default_logout_urls = [
    "https://${local.domain_name}/argocd/",
    "https://${local.domain_name}/jenkins/",
    "https://${local.domain_name}/grafana/",
  ]

  # Tailnet (internal) OIDC URLs — empty unless var.tailscale is set. Internal mode
  # exposes every app on ONE tailnet host (a single Tailscale device fronts Traefik,
  # which path-routes /argocd, /grafana, …), so these mirror the external, path-based
  # URLs — just on the tailnet host instead of the public domain. The host is derived
  # from var.tailscale, which must match subsystems.tailscale in the cluster root;
  # see variables.tf for the contract.
  tailscale_base_url = var.tailscale == null ? null : "https://${var.tailscale.hostname_prefix}.${var.tailscale.magic_dns_name}"

  tailscale_callback_urls = var.tailscale == null ? [] : [
    "${local.tailscale_base_url}/argocd/auth/callback",
    "${local.tailscale_base_url}/jenkins/securityRealm/finishLogin",
    "${local.tailscale_base_url}/grafana/login/generic_oauth",
  ]

  tailscale_logout_urls = var.tailscale == null ? [] : [
    "${local.tailscale_base_url}/argocd/",
    "${local.tailscale_base_url}/jenkins/",
    "${local.tailscale_base_url}/grafana/",
  ]

}

module "idp" {
  source   = "../modules/idp_cognito"
  nickname = var.nickname
  callback_urls = concat(
    local.default_callback_urls,
    local.tailscale_callback_urls
  )
  logout_urls = concat(
    local.default_logout_urls,
    local.tailscale_logout_urls
  )

}
