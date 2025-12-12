output "k3s_cluster_load_balancer" {
    description = "k3s cluster load balancer"
    value       = aws_lb.elb_main
}

