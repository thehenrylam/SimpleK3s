output "vpc_id" {
    description = "The ID of the created VPC"
    value       = aws_vpc.vpc.id
}

output "subnet_public_ids" {
    description = "The IDs of the public subnet"
    value       = [for s in aws_subnet.sbn_public : s.id]
}
