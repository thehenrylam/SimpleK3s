output "ssm_param_name" {
  description = "SSM parameter name — paste this as subsystems.tailscale.pstore_oauth in examples/ex_basic"
  value       = aws_ssm_parameter.tailscale_oauth.name
}

output "cleanup_lambda_arn" {
  description = "ARN of the device-cleanup Lambda (ex_basic reads this from SSM to wire its destroy-time invocation)"
  value       = aws_lambda_function.cleanup.arn
}

output "cleanup_lambda_arn_ssm_param" {
  description = "SSM parameter name holding the cleanup Lambda ARN (read by examples/ex_basic)"
  value       = aws_ssm_parameter.cleanup_lambda_arn.name
}

output "list_lambda_name" {
  description = "Name of the read-only device-list Lambda (invoke ad-hoc: aws lambda invoke --function-name <this>)"
  value       = aws_lambda_function.list.function_name
}

output "preflight_lambda_arn" {
  description = "ARN of the read-only preflight Lambda (ex_basic reads this from SSM to gate the deploy)"
  value       = aws_lambda_function.preflight.arn
}

output "preflight_lambda_arn_ssm_param" {
  description = "SSM parameter name holding the preflight Lambda ARN (read by examples/ex_basic)"
  value       = aws_ssm_parameter.preflight_lambda_arn.name
}
