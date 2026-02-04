data "aws_ssm_parameter" "issuer" {
    name            = var.idp_ssm_param_names.issuer
    with_decryption = true
}

data "aws_ssm_parameter" "client" {
    name            = var.idp_ssm_param_names.client
    with_decryption = true
}

data "aws_ssm_parameter" "secret" {
    name            = var.idp_ssm_param_names.secret
    with_decryption = true
}
