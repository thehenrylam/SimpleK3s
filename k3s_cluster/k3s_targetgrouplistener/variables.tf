variable "nickname" {
    description = "The nickname of the module"
    type        = string
}

variable "vpc_id" {
    description = "The vpc id that the module will reside in"
    type        = string
}

variable "load_balancer_arn" {
    description = "The ARN of the load balancer to attach the listener to"
    type        = string
}

variable "target_ids" {
    description = "The list of target IDs (e.g. EC2 instance IDs) to attach to the target group"
    type        = list(string)
}

variable "target_group_port" {
    description = "The port for the target group (The Port that the EC2 instances are listening on)"
    type        = number
}

variable "listener_port" {
    description = "The port for the load balancer listener (The Port that the Load Balancer will listen on)"
    type        = number
}

variable "protocol" {
    description = "The protocol for the load balancer listener and target group"
    type        = string
    default     = "TCP"
}
