output "s3obj_list" {
    description = "The list of s3 objects set up for the k3s_app"
    value       = [ for obj in aws_s3_object.s3obj : obj.key ]
}