terraform {
    required_version = ">= 1.11.0"

    required_providers {
        aws = {
            source  = "hashicorp/aws"
            version = ">= 6.0.0"
        }
        random = {
            source  = "hashicorp/random"
            version = ">= 3.5.0"
        }
    }
}

locals {
    # General settings
    upl_name = "idp-upl-${var.nickname}"
    upc_name = "idp-upc-${var.nickname}"
    pstore_issuer_name = "idp-pstore-issuer-${var.nickname}" 
    pstore_client_name = "idp-pstore-client-${var.nickname}" 
    pstore_secret_name = "idp-pstore-secret-${var.nickname}" 
    pstore_config_name = "idp-pstore-config-${var.nickname}"

    # SSM parameters key root
    ssm_parameters_key_root = "/idp-standalone/${var.nickname}"

    tags_default = {
        Nickname = "${var.nickname}"
    }
}

data "aws_region" "current" {}

###########################
#   Derive local values   #
###########################
locals {
    # Issuer is used by apps to discover OIDC endpoints via .well-known
    issuer_url      = "https://cognito-idp.${data.aws_region.current.region}.amazonaws.com/${aws_cognito_user_pool.this.id}"

    hosted_ui_base  = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${data.aws_region.current.region}.amazoncognito.com"

    domain_prefix   = "idp-${var.nickname}-${data.aws_region.current.region}"
}

# 1) User Pool
resource "aws_cognito_user_pool" "this" {
    name = "${local.upl_name}"

    # Keep it simple for dev: email as username
    username_attributes      = ["email"]
    auto_verified_attributes = ["email"]

    password_policy {
        minimum_length    = 12
        require_lowercase = true
        require_uppercase = true
        require_numbers   = true
        require_symbols   = true
    }

    admin_create_user_config {
        allow_admin_create_user_only = true
    }

    account_recovery_setting {
        recovery_mechanism {
            name     = "verified_email"
            priority = 1
        }
    }

    tags = merge(var.tags, merge(local.tags_default, {
        Name = local.upl_name
    }))
}

# 2) Hosted UI domain (AWS-managed)
resource "aws_cognito_user_pool_domain" "this" {
    domain       = local.domain_prefix
    user_pool_id = aws_cognito_user_pool.this.id
}

# 3) App Client (OIDC)
resource "aws_cognito_user_pool_client" "this" {
    name            = "${local.upc_name}"
    user_pool_id    = aws_cognito_user_pool.this.id

    generate_secret = true

    supported_identity_providers = var.supported_identity_providers

    callback_urls   = var.callback_urls
    logout_urls     = var.logout_urls

    allowed_oauth_flows_user_pool_client    = true
    allowed_oauth_flows                     = ["code"] # Authorization Code flow
    allowed_oauth_scopes                    = var.oauth_scopes

    # Useful defaults
    explicit_auth_flows = [
        "ALLOW_REFRESH_TOKEN_AUTH",
        "ALLOW_USER_SRP_AUTH",
        "ALLOW_USER_PASSWORD_AUTH"
    ]
}

# Optional: Group names
resource "aws_cognito_user_group" "group" {
    for_each        = { for i, o in var.group_names : i => o }
    name            = each.value
    user_pool_id    = aws_cognito_user_pool.this.id
    description     = "Group for RBAC mapping - ${each.value}"
}

# Optional: Define users
resource "aws_cognito_user" "users" {
    for_each        = { for i, o in var.users : i => o }
    user_pool_id    = aws_cognito_user_pool.this.id
    username        = each.value.username

    attributes = {
        email           = each.value.username
        email_verified  = "true"
    }

    temporary_password  = random_password.tmp[each.key].result
    message_action      = "SUPPRESS"
}
resource "random_password" "tmp" {
    count   = length(var.users)
    length  = 20
    special = true
}

# Optional: Link users to groups
resource "aws_cognito_user_in_group" "test_user_group" {
    for_each        = { for i, o in var.users : o.username => o.group if o.group != null }
    user_pool_id    = aws_cognito_user_pool.this.id
    username        = each.key
    group_name      = each.value
}

