output "processed_s3obj" {
  description = "The list of s3 objects set up for the cluster_app"
  value       = module.aws_s3obj.processed_s3obj
}

output "processed_pstores" {
  description = "The list of pstores processed"
  value       = []
}

output "default_pool_name" {
  description = "Name of the pool marked default=true (null if none)"
  value       = one([for p in local.settings.pools : p.name if p.default])
}
