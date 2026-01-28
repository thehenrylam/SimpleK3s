output "user_pool_id" {
    value = aws_cognito_user_pool.this.id
}

output "client_id" {
    value = aws_cognito_user_pool_client.this.id
}

output "client_secret" {
    value     = aws_cognito_user_pool_client.this.client_secret
    sensitive = true
}

output "issuer_url" {
    value = local.issuer_url
}

output "discovery_url" {
    value = "${local.issuer_url}/.well-known/openid-configuration"
}

output "hosted_ui_base_url" {
    value = local.hosted_ui_base
}

output "authorize_url" {
    value = "${local.hosted_ui_base}/oauth2/authorize"
}

output "token_url" {
    value = "${local.hosted_ui_base}/oauth2/token"
}

output "userinfo_url" {
    value = "${local.hosted_ui_base}/oauth2/userInfo"
}
