output "listener_arn" {
    description = "The ARN of the load balancer listener"
    value       = aws_lb_listener.listener.arn
}

output "target_group_arn" {
    description = "The ARN of the load balancer target group"
    value       = aws_lb_target_group.tgroup.arn
}
