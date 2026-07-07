output "ssm_param_name" {
  description = "SSM parameter name — paste this as subsystems.tailscale.pstore_oauth in examples/ex_basic"
  value       = aws_ssm_parameter.tailscale_oauth.name
}
