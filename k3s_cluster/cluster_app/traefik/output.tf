output "processed_s3obj" {
    description = "The list of s3 objects set up for the cluster_app"
    value       = module.aws_s3obj.processed_s3obj 
}

output "processed_pstores" {
    description = "The list of pstores processed"
    value       = [] # No aws_pstore was used, still provide an empty output for future expansion
}