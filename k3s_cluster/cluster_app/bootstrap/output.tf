output "processed_s3obj" {
  description = "The list of s3 objects set up for the cluster_app"
  value       = module.aws_s3obj.processed_s3obj
}

output "s3key_install_script" {
  description = "S3 key of the cloud-init entry point script (node_init-all.sh)"
  # Named explicitly rather than read positionally out of processed_s3obj, whose
  # order is not meaningful.
  value = local.s3key_install_script
}

output "processed_pstores" {
  description = "The list of pstores processed"
  value       = [] # No aws_pstore was used, still provide an empty output for future expansion
}