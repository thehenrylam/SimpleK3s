terraform {
    required_providers {
        aws = {
            source  = "hashicorp/aws"
            version = ">= 6.0"
        }
    }
}

locals {
    tgroup_name_base    = "tgroup-k3s-${var.nickname}"
    tgroup_name         = "${local.tgroup_name_base}-${var.target_group_port}" 
    listener_name_base  = "listener-k3s-${var.nickname}"
    listener_name       = "${local.listener_name_base}-${var.listener_port}"
}


# Define the listener (Checks for connection requests from clients and forwards them to the target group)
resource "aws_lb_listener" "listener" {
    load_balancer_arn = var.load_balancer_arn
    port              = var.listener_port 
    protocol          = var.protocol

    default_action {
        type             = "forward"
        target_group_arn = aws_lb_target_group.tgroup.arn
    }

    tags = {
        Name        = "${local.listener_name}"
        Nickname    = "${var.nickname}"
    }
}

# Define the target group (A group of resources that the load balancer routes traffic to)
resource "aws_lb_target_group" "tgroup" {
    name     = "${local.tgroup_name}"
    port     = var.target_group_port 
    protocol = var.protocol
    vpc_id   = var.vpc_id

    tags = {
        Name        = "${local.tgroup_name}"
        Nickname    = "${var.nickname}"
    }
}

# Attach targets (e.g. EC2 instances) to the target group
resource "aws_lb_target_group_attachment" "tgroup_attachment" {
    count               = length(var.target_ids)
    target_group_arn    = aws_lb_target_group.tgroup.arn
    target_id           = var.target_ids[count.index]
    port                = var.target_group_port
}
