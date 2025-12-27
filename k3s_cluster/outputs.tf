output "k3s_cluster_load_balancer" {
    description = "k3s cluster load balancer"
    value       = aws_lb.elb_main
}

output "k3s_controller_public_ip" {
    description = "K3s controller's Public IP"
    value       = aws_instance.ec2_node[0].public_ip
}

output "ssh_private_key_path" {
    description = "SSH Private Key Path"
    value       = local_file.private_key.filename
}

