output "issuer_url" {
    value = module.idp.issuer_url
}

output "ssm_params_idp_issuer_name" {
    value = module.idp.pstore_key_issuer
}

output "ssm_params_idp_client_name" {
    value = module.idp.pstore_key_client
}

output "ssm_params_idp_secret_name" {
    value = module.idp.pstore_key_secret
}
