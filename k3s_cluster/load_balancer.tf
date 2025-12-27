###############################################
#    Elastic Load Balancer for K3s cluster    #
###############################################
# Create a application load balancer
resource "aws_lb" "elb_main" {
    name               = "${local.elb_name}"
    internal           = false
    load_balancer_type = "network"
    security_groups    = [aws_security_group.sg_elb.id]
    subnets            = [for subnet_id in var.subnet_ids : subnet_id ] # <-- Connect this up

    tags = {
        Name        = "${local.elb_name}"
        Nickname    = "${var.nickname}"
    }
}

###########################################################
#    Target Group & Listener (Port 80) for K3s cluster    #
###########################################################
module "k3s_tgl_http" {
    source              = "./k3s_targetgrouplistener"
    nickname            = var.nickname
    vpc_id              = var.vpc_id
    load_balancer_arn   = aws_lb.elb_main.arn
    target_ids          = [for instance in aws_instance.ec2_node : instance.id ]
    target_group_port   = var.k3s_nodeport_traefik_http # Traefik port that represents port 80
    listener_port       = 80
}

############################################################
#    Target Group & Listener (Port 443) for K3s cluster    #
############################################################
module "k3s_tgl_https" {
    source              = "./k3s_targetgrouplistener"
    nickname            = var.nickname
    vpc_id              = var.vpc_id
    load_balancer_arn   = aws_lb.elb_main.arn
    target_ids          = [for instance in aws_instance.ec2_node : instance.id ]
    target_group_port   = var.k3s_nodeport_traefik_https # Traefik port that represents port 443
    listener_port       = 443
}
