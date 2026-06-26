###########################################
#    Security Groups for EC2 instances    #
###########################################
# Set up security groups 
resource "aws_security_group" "sg_instances" {
  name        = local.sg_ec2_name
  description = "Private SG for Cluster Nodes"
  vpc_id      = var.vpc_id

  tags = {
    Name     = local.sg_ec2_name
    Nickname = var.nickname
  }
}

#############################
#   SSH Access for Admins   #
#############################
# Allow SSH from admin IPs (one rule per CIDR — the single-rule resource takes
# a single CIDR, so we fan out the admin_ip_list here)
resource "aws_vpc_security_group_ingress_rule" "sgr_ssh_admin" {
  for_each          = toset(var.admin_ip_list)
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value
  security_group_id = aws_security_group.sg_instances.id
  description       = "SSH from admin (${each.value})"
}

# Warn (non-fatal) if SSH is open to the world — lets the developer consciously proceed
check "sgr_ssh_admin_open_access" {
  assert {
    condition     = !contains(var.admin_ip_list, "0.0.0.0/0")
    error_message = "SSH (port 22) is open to 0.0.0.0/0 — confirm this is intentional."
  }
}

########################################################################
#   HTTP and HTTPS Access for Internal Processes (Package Downloads)   #
########################################################################
# Allow HTTP egress (Package Downloads, etc)
module "k3s_sgr_node_http" {
  source            = "./k3s_securitygrouprule/cidr"
  type              = "egress" # Egress only
  port              = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.sg_instances.id
  description       = "Egress HTTP (package downloads)"
}

# Allow HTTPS egress (Package Downloads, etc)
module "k3s_sgr_node_https" {
  source            = "./k3s_securitygrouprule/cidr"
  type              = "egress" # Egress only
  port              = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.sg_instances.id
  description       = "Egress HTTPS (package downloads)"
}

############################################################################
#   Traefik NodePorts to be used for Load Balancer (Access to End-Users)   #
############################################################################
# Allow Traefik NodePorts whose traffic is handled by Load Balancer (HTTP : Port 80)
module "k3s_sgr_traefik_http" {
  source                   = "./k3s_securitygrouprule/sgroup"
  type                     = "ingress" # Ingress only (Access from LB)
  port                     = var.k3s_nodeport_traefik_http
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.sg_elb.id
  security_group_id        = aws_security_group.sg_instances.id
  description              = "Traefik NodePort for HTTP (from LB only)"
}

# Allow Traefik NodePorts whose traffic is handled by Load Balancer (HTTPS : Port 443)
module "k3s_sgr_traefik_https" {
  source                   = "./k3s_securitygrouprule/sgroup"
  type                     = "ingress" # Ingress only (Access from LB)
  port                     = var.k3s_nodeport_traefik_https
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.sg_elb.id
  security_group_id        = aws_security_group.sg_instances.id
  description              = "Traefik NodePort for HTTPS (from LB only)"
}

####################################################################
#   Foundational Kubernetes Cluster External Communication Ports   #
####################################################################
# Allow DNS queries for UDP and TCP (This is so that nodes can resolve domain names (e.g., for package downloads))
resource "aws_vpc_security_group_egress_rule" "sgr_dns_udp" {
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
  cidr_ipv4         = local.vpc_dns_resolver_cidr # VPC DNS Resolver CIDR block is used instead of "0.0.0.0/0"
  security_group_id = aws_security_group.sg_instances.id
  description       = "DNS egress (UDP)"
}
resource "aws_vpc_security_group_egress_rule" "sgr_dns_tcp" {
  from_port         = 53
  to_port           = 53
  ip_protocol       = "tcp"
  cidr_ipv4         = local.vpc_dns_resolver_cidr # VPC DNS Resolver CIDR block is used instead of "0.0.0.0/0"
  security_group_id = aws_security_group.sg_instances.id
  description       = "DNS egress (TCP)"
}

###############################################################################################
#   Foundational Kubernetes Cluster Internal Communication Ports                              #
#   Link to Docs: https://docs.k3s.io/installation/requirements#inbound-rules-for-k3s-nodes   #
###############################################################################################
# Allow Kube-API access for cross-node cluster
module "k3s_sgr_kubeapi" {
  source            = "./k3s_securitygrouprule/self"
  type              = "both" # Ingress + Egress
  port              = 6443
  protocol          = "tcp"
  security_group_id = aws_security_group.sg_instances.id
  description       = "Kube-API server port"
}

# Allow Kubelet metrics access for cross-node cluster
module "k3s_sgr_kubelet_metrics" {
  source            = "./k3s_securitygrouprule/self"
  type              = "both" # Ingress + Egress
  port              = 10250
  protocol          = "tcp"
  security_group_id = aws_security_group.sg_instances.id
  description       = "Kubelet read-only metrics port"
}

# Allow node-exporter metrics scraping across nodes. node-exporter runs with
# hostNetwork and is scraped at nodeIP:9100 (off the flannel overlay), so without
# this self-rule Prometheus can only reach the node-exporter co-located on its own
# node — every other node's target shows DOWN and Grafana's node dashboards list a
# single instance.
module "k3s_sgr_node_exporter_metrics" {
  source            = "./k3s_securitygrouprule/self"
  type              = "both" # Ingress + Egress
  port              = 9100
  protocol          = "tcp"
  security_group_id = aws_security_group.sg_instances.id
  description       = "node-exporter metrics port (cross-node Prometheus scraping)"
}

# Allow Flannel for cross-node cluster
module "k3s_sgr_flannel" {
  source            = "./k3s_securitygrouprule/self"
  type              = "both" # Ingress + Egress
  port              = 8472
  protocol          = "udp"
  security_group_id = aws_security_group.sg_instances.id
  description       = "Flannel VXLAN port"
}

# Allow ETCD ports for cross-node cluster (2379 and 2380)
module "k3s_sgr_etcd_2379" {
  source            = "./k3s_securitygrouprule/self"
  type              = "both" # Ingress + Egress
  port              = 2379
  protocol          = "tcp"
  security_group_id = aws_security_group.sg_instances.id
  description       = "ETCD client communication port"
}
module "k3s_sgr_etcd_2380" {
  source            = "./k3s_securitygrouprule/self"
  type              = "both" # Ingress + Egress
  port              = 2380
  protocol          = "tcp"
  security_group_id = aws_security_group.sg_instances.id
  description       = "ETCD cross-node communication port"
}
