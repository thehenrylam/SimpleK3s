resource "aws_ssm_parameter" "idp_issuer" {
    description = "IdP - IdP Issuer"
    type        = "SecureString"
    name        = "${local.ssm_parameters_key_root}/idp_issuer"
    value       = local.issuer_url

    tags = merge(var.tags, local.tags_default, {
        Name = local.pstore_issuer_name 
    })
}

resource "aws_ssm_parameter" "idp_client" {
    description = "IdP - IdP Client"
    type        = "SecureString"
    name        = "${local.ssm_parameters_key_root}/idp_client"
    value       = aws_cognito_user_pool_client.this.id

    tags = merge(var.tags, local.tags_default, {
        Name = local.pstore_client_name 
    })
}

resource "aws_ssm_parameter" "idp_secret" {
    description = "IdP - IdP Secret"
    type        = "SecureString"
    name        = "${local.ssm_parameters_key_root}/idp_secret"
    value       = aws_cognito_user_pool_client.this.client_secret

    tags = merge(var.tags, local.tags_default, {
        Name = local.pstore_secret_name 
    })
}
