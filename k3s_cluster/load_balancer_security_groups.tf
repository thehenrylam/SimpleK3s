########################################
# Security Group for the Load Balancer #
########################################
resource "aws_security_group" "sg_elb" {
    name        = "${local.sg_elb_name}"
    description = "Public SG for Load Balancer"
    vpc_id      = var.vpc_id

    tags = {
        Name     = "${local.sg_elb_name}"
        Nickname = "${var.nickname}"
    }
}

# Inbound: public HTTP/HTTPS
module "elb_ingress_http" {
    source              = "./k3s_securitygrouprule/cidr"
    type                = "ingress"
    port                = 80
    protocol            = "tcp"
    cidr_blocks         = ["0.0.0.0/0"]
    security_group_id   = aws_security_group.sg_elb.id
    description         = "Port from Public to LB for HTTP"
}

module "elb_ingress_https" {
    source              = "./k3s_securitygrouprule/cidr"
    type                = "ingress"
    port                = 443
    protocol            = "tcp"
    cidr_blocks         = ["0.0.0.0/0"]
    security_group_id   = aws_security_group.sg_elb.id
    description         = "Port from Public to LB for HTTPS"
}

# Outbound: only to instances on Traefik NodePorts
module "elb_egress_to_nodes_http" {
    source                      = "./k3s_securitygrouprule/sgroup"
    type                        = "egress"
    port                        = var.k3s_nodeport_traefik_http
    protocol                    = "tcp"
    source_security_group_id    = aws_security_group.sg_instances.id
    security_group_id           = aws_security_group.sg_elb.id
    description                 = "Traefik NodePort from LB to Nodes for HTTP"
}

module "elb_egress_to_nodes_https" {
    source                      = "./k3s_securitygrouprule/sgroup"
    type                        = "egress"
    port                        = var.k3s_nodeport_traefik_https
    protocol                    = "tcp"
    source_security_group_id    = aws_security_group.sg_instances.id
    security_group_id           = aws_security_group.sg_elb.id
    description                 = "Traefik NodePort from LB to Nodes for HTTPS"
}
