###########################################
#    Security Groups for EC2 instances    #
###########################################
# Set up security groups 
resource "aws_security_group" "sg_instances" {
    name          = "k8s_node_sg"
    description   = "K8s node secuirty group"
    vpc_id        = var.vpc_id

    tags = {
        Name = "k8s_node_sg"
    }
}

#############################
#   SSH Access for Admins   #
#############################
# Allow SSH from admin IPs 
resource "aws_security_group_rule" "sgr_ssh_admin" {
    type                     = "ingress"
    from_port                = 22
    to_port                  = 22
    protocol                 = "tcp"
    cidr_blocks              = var.admin_ip_list
    security_group_id        = aws_security_group.sg_instances.id
}

############################
#   DNS Access for Nodes   #
############################
# Allow DNS queries (UDP and TCP)
resource "aws_security_group_rule" "sgr_dns_udp" {
    type                     = "egress"
    from_port                = 53
    to_port                  = 53
    protocol                 = "udp"
    cidr_blocks              = ["0.0.0.0/0"]
    security_group_id        = aws_security_group.sg_instances.id
}
resource "aws_security_group_rule" "sgr_dns_tcp" {
    type                     = "egress"
    from_port                = 53
    to_port                  = 53
    protocol                 = "tcp"
    cidr_blocks              = ["0.0.0.0/0"]
    security_group_id        = aws_security_group.sg_instances.id
}

###########################################
#   HTTP and HTTPS Access for End-Users   #
###########################################
# Allow HTTP from anywhere (Ingress + Egress)
resource "aws_security_group_rule" "sgr_http_ingress_all" {
    type                     = "ingress"
    from_port                = 80
    to_port                  = 80
    protocol                 = "tcp"
    cidr_blocks              = ["0.0.0.0/0"]
    security_group_id        = aws_security_group.sg_instances.id
}
resource "aws_security_group_rule" "sgr_http_egress_all" {
    type                     = "egress"
    from_port                = 80
    to_port                  = 80
    protocol                 = "tcp"
    cidr_blocks              = ["0.0.0.0/0"]
    security_group_id        = aws_security_group.sg_instances.id
}

# Allow HTTPS from anywhere (Ingress + Egress)
resource "aws_security_group_rule" "sgr_https_ingress_all" {
    type                     = "ingress"
    from_port                = 443
    to_port                  = 443
    protocol                 = "tcp"
    cidr_blocks              = ["0.0.0.0/0"]
    security_group_id        = aws_security_group.sg_instances.id
}
resource "aws_security_group_rule" "sgr_https_egress_all" {
    type                     = "egress"
    from_port                = 443
    to_port                  = 443
    protocol                 = "tcp"
    cidr_blocks              = ["0.0.0.0/0"]
    security_group_id        = aws_security_group.sg_instances.id
}

############################################################################
#   Traefik NodePorts to be used for Load Balancer (Access to End-Users)   #
############################################################################
# Allow Traefik NodePorts for cross-node cluster (HTTP : Port 80)
resource "aws_security_group_rule" "sgr_traefik_http_ingress_self" {
    type                     = "ingress"
    from_port                = var.k3s_nodeport_traefik_http
    to_port                  = var.k3s_nodeport_traefik_http
    protocol                 = "tcp"
    self                     = true
    security_group_id        = aws_security_group.sg_instances.id
}
resource "aws_security_group_rule" "sgr_traefik_http_egress_self" {
    type                     = "egress"
    from_port                = var.k3s_nodeport_traefik_http
    to_port                  = var.k3s_nodeport_traefik_http
    protocol                 = "tcp"
    self                     = true
    security_group_id        = aws_security_group.sg_instances.id
}

# Allow Traefik NodePorts for cross-node cluster (HTTPS : Port 443)
resource "aws_security_group_rule" "sgr_traefik_https_ingress_self" {
    type                     = "ingress"
    from_port                = var.k3s_nodeport_traefik_https
    to_port                  = var.k3s_nodeport_traefik_https
    protocol                 = "tcp"
    self                     = true
    security_group_id        = aws_security_group.sg_instances.id
}
resource "aws_security_group_rule" "sgr_traefik_https_egress_self" {
    type                     = "egress"
    from_port                = var.k3s_nodeport_traefik_https
    to_port                  = var.k3s_nodeport_traefik_https
    protocol                 = "tcp"
    self                     = true
    security_group_id        = aws_security_group.sg_instances.id
}

###############################################################################################
#   Foundational Kubernetes Cluster Internal Communication Ports                              #
#   Link to Docs: https://docs.k3s.io/installation/requirements#inbound-rules-for-k3s-nodes   #
###############################################################################################
# Allow Kube-API access for cross-node cluster
resource "aws_security_group_rule" "sgr_kubeapi_ingress_self" {
    type                     = "ingress"
    from_port                = 6443
    to_port                  = 6443
    protocol                 = "tcp"
    self                     = true
    security_group_id        = aws_security_group.sg_instances.id
}
resource "aws_security_group_rule" "sgr_kubeapi_egress_self" {
    type                     = "egress"
    from_port                = 6443
    to_port                  = 6443
    protocol                 = "tcp"
    self                     = true
    security_group_id        = aws_security_group.sg_instances.id
}

# Allow Kubelet metrics access for cross-node cluster
resource "aws_security_group_rule" "sgr_kubelet_ingress_self" {
    type                     = "ingress"
    from_port                = 10250
    to_port                  = 10250
    protocol                 = "tcp"
    self                     = true
    security_group_id        = aws_security_group.sg_instances.id
}
resource "aws_security_group_rule" "sgr_kubelet_egress_self" {
    type                     = "egress"
    from_port                = 10250
    to_port                  = 10250
    protocol                 = "tcp"
    self                     = true
    security_group_id        = aws_security_group.sg_instances.id
}

# Allow Flannel for cross-node cluster
resource "aws_security_group_rule" "sgr_flannel_ingress_self" {
    type                     = "ingress"
    from_port                = 8472
    to_port                  = 8472
    protocol                 = "udp"
    self                     = true
    security_group_id        = aws_security_group.sg_instances.id
}
resource "aws_security_group_rule" "sgr_flannel_egress_self" {
    type                     = "egress"
    from_port                = 8472
    to_port                  = 8472
    protocol                 = "udp"
    self                     = true
    security_group_id        = aws_security_group.sg_instances.id
}

# Allow ETCD ports for cross-node cluster (2379 and 2380)
resource "aws_security_group_rule" "sgr_etcd_2379_ingress_self" {
    type                     = "ingress"
    from_port                = 2379
    to_port                  = 2379
    protocol                 = "tcp"
    self                     = true
    security_group_id        = aws_security_group.sg_instances.id
}
resource "aws_security_group_rule" "sgr_etcd_2379_egress_self" {
    type                     = "egress"
    from_port                = 2379
    to_port                  = 2379
    protocol                 = "tcp"
    self                     = true
    security_group_id        = aws_security_group.sg_instances.id
}
resource "aws_security_group_rule" "sgr_etcd_2380_ingress_self" {
    type                     = "ingress"
    from_port                = 2380
    to_port                  = 2380
    protocol                 = "tcp"
    self                     = true
    security_group_id        = aws_security_group.sg_instances.id
}
resource "aws_security_group_rule" "sgr_etcd_2380_egress_self" {
    type                     = "egress"
    from_port                = 2380
    to_port                  = 2380
    protocol                 = "tcp"
    self                     = true
    security_group_id        = aws_security_group.sg_instances.id
}
