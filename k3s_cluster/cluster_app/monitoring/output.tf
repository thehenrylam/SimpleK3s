output "processed_s3obj" {
    description = "The list of s3 objects set up for the cluster_app"
    value       = module.aws_s3obj.processed_s3obj 
}

output "processed_pstores" {
    description = "The list of pstores processed"
    value       = module.aws_pstore.processed_pstores
}