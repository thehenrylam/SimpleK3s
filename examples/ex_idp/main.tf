# OPENTOFU : IdP (Identification Provider) Standalone

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    assert = {
      source  = "opentofu/assert"
      version = "0.14.0"
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

}

module "idp" {
  source   = "../modules/idp_cognito"
  nickname = var.nickname
  callback_urls = [
    "https://${local.domain_name}/argocd/auth/callback",
    "https://${local.domain_name}/jenkins/securityRealm/finishLogin",
    "https://${local.domain_name}/grafana/login/generic_oauth",
    "https://${local.domain_name}/oauth2/oauth2/callback",
  ]
  logout_urls = [
    "https://${local.domain_name}/argocd/",
    "https://${local.domain_name}/jenkins/",
    "https://${local.domain_name}/grafana/",
  ]

}
