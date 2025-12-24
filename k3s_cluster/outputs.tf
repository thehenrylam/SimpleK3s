output "k3s_cluster_load_balancer" {
    description = "k3s cluster load balancer"
    value       = aws_lb.elb_main
}

output "k3s_controller_public_ip" {
  value = aws_instance.ec2_node[0].public_ip
}

output "ssh_private_key_path" {
  value = local_file.private_key.filename
}

