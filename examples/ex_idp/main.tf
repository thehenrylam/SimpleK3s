# OPENTOFU : IdP (Identification Provider) Standalone

terraform {
    required_version = ">= 1.11.0"

    required_providers {
        aws = {
            source  = "hashicorp/aws"
            version = ">= 6.0"
        }
        assert = {
            source = "opentofu/assert"
            version = "0.14.0"
        }
    }
}

provider "aws" {
    region = var.aws_region
}

locals {
    dns_basename  = var.dns.basename
    dns_prefix    = coalesce(var.dns.prefix, "k3s")

    modules_path = "../modules/"
    domain_name="${local.dns_prefix}.${local.dns_basename}"

    pstore_key_root = "/idp-standalone/${var.nickname}"

    pstore_issuer_name = "pstore-idp_issuer-${var.nickname}"
    pstore_client_name = "pstore-idp_client-${var.nickname}"
    pstore_secret_name = "pstore-idp_secret-${var.nickname}"
}

module "idp" {
    source = "${local.modules_path}/idp_cognito"
    nickname        = "${var.nickname}"
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
