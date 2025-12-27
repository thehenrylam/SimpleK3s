###########################################
#    Security Groups for EC2 instances    #
###########################################
# Set up security groups 
resource "aws_security_group" "sg_instances" {
    name          = "${local.sg_ec2_name}"
    description   = "Private SG for Cluster Nodes"
    vpc_id        = var.vpc_id

    tags = {
        Name        = "${local.sg_ec2_name}"
        Nickname    = "${var.nickname}"
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

########################################################################
#   HTTP and HTTPS Access for Internal Processes (Package Downloads)   #
########################################################################
# Allow HTTP egress (Package Downloads, etc)
module "k3s_sgr_node_http" {
    source              = "./k3s_securitygrouprule_cidr"
    type                = "egress" # Egress only
    port                = 80
    protocol            = "tcp"
    cidr_blocks         = ["0.0.0.0/0"]
    security_group_id   = aws_security_group.sg_instances.id
    description         = "Egress HTTP (package downloads)"
}

# Allow HTTPS egress (Package Downloads, etc)
module "k3s_sgr_node_https" {
    source              = "./k3s_securitygrouprule_cidr"
    type                = "egress" # Egress only
    port                = 443
    protocol            = "tcp"
    cidr_blocks         = ["0.0.0.0/0"]
    security_group_id   = aws_security_group.sg_instances.id
    description         = "Egress HTTPS (package downloads)"
}

############################################################################
#   Traefik NodePorts to be used for Load Balancer (Access to End-Users)   #
############################################################################
# Allow Traefik NodePorts whose traffic is handled by Load Balancer (HTTP : Port 80)
module "k3s_sgr_traefik_http" {
    source                      = "./k3s_securitygrouprule_sgroup"
    type                        = "ingress" # Ingress only (Access from LB)
    port                        = var.k3s_nodeport_traefik_http
    protocol                    = "tcp"
    source_security_group_id    = aws_security_group.sg_elb.id
    security_group_id           = aws_security_group.sg_instances.id
    description                 = "Traefik NodePort for HTTP (from LB only)"
}

# Allow Traefik NodePorts whose traffic is handled by Load Balancer (HTTPS : Port 443)
module "k3s_sgr_traefik_https" {
    source                      = "./k3s_securitygrouprule_sgroup"
    type                        = "ingress" # Ingress only (Access from LB)
    port                        = var.k3s_nodeport_traefik_https
    protocol                    = "tcp"
    source_security_group_id    = aws_security_group.sg_elb.id
    security_group_id           = aws_security_group.sg_instances.id
    description                 = "Traefik NodePort for HTTPS (from LB only)"
}

####################################################################
#   Foundational Kubernetes Cluster External Communication Ports   #
####################################################################
# Allow DNS queries for UDP and TCP (This is so that nodes can resolve domain names (e.g., for package downloads))
resource "aws_security_group_rule" "sgr_dns_udp" {
    type                     = "egress"
    from_port                = 53
    to_port                  = 53
    protocol                 = "udp"
    cidr_blocks              = [local.vpc_dns_resolver_cidr] # VPC DNS Resolver CIDR block is used instead of "0.0.0.0/0"
    security_group_id        = aws_security_group.sg_instances.id
}
resource "aws_security_group_rule" "sgr_dns_tcp" {
    type                     = "egress"
    from_port                = 53
    to_port                  = 53
    protocol                 = "tcp"
    cidr_blocks              = [local.vpc_dns_resolver_cidr] # VPC DNS Resolver CIDR block is used instead of "0.0.0.0/0"
    security_group_id        = aws_security_group.sg_instances.id
}

###############################################################################################
#   Foundational Kubernetes Cluster Internal Communication Ports                              #
#   Link to Docs: https://docs.k3s.io/installation/requirements#inbound-rules-for-k3s-nodes   #
###############################################################################################
# Allow Kube-API access for cross-node cluster
module "k3s_sgr_kubeapi" {
    source              = "./k3s_securitygrouprule_self"
    type                = "both" # Ingress + Egress
    port                = 6443
    protocol            = "tcp"
    security_group_id   = aws_security_group.sg_instances.id
    description         = "Kube-API server port"
}

# Allow Kubelet metrics access for cross-node cluster
module "k3s_sgr_kubelet_metrics" {
    source              = "./k3s_securitygrouprule_self"
    type                = "both" # Ingress + Egress
    port                = 10250
    protocol            = "tcp"
    security_group_id   = aws_security_group.sg_instances.id
    description         = "Kubelet read-only metrics port"
}

# Allow Flannel for cross-node cluster
module "k3s_sgr_flannel" {
    source              = "./k3s_securitygrouprule_self"
    type                = "both" # Ingress + Egress
    port                = 8472
    protocol            = "udp"
    security_group_id   = aws_security_group.sg_instances.id
    description         = "Flannel VXLAN port"
}

# Allow ETCD ports for cross-node cluster (2379 and 2380)
module "k3s_sgr_etcd_2379" {
    source              = "./k3s_securitygrouprule_self"
    type                = "both" # Ingress + Egress
    port                = 2379
    protocol            = "tcp"
    security_group_id   = aws_security_group.sg_instances.id
    description         = "ETCD client communication port"
}
module "k3s_sgr_etcd_2380" {
    source              = "./k3s_securitygrouprule_self"
    type                = "both" # Ingress + Egress
    port                = 2380
    protocol            = "tcp"
    security_group_id   = aws_security_group.sg_instances.id
    description         = "ETCD cross-node communication port"
}
