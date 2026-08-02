output "ssm_param_names" {
  description = "SSM parameter names per pool — paste these as ebs_volumes_pstore_name in examples/standard_deployment/terraform/standard_cluster"
  value = {
    for name, param in aws_ssm_parameter.pool_volumes : name => param.name
  }
}

output "volume_ids" {
  description = "EBS volume IDs grouped by pool name, for reference and tagging"
  value       = local.pool_volume_ids
}
