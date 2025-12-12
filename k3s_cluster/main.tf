terraform {
    required_providers {
        assert = {
            source = "opentofu/assert"
            version = "0.14.0"
        }
        aws = {
            source  = "hashicorp/aws"
            version = ">= 6.0"
        }
        cloudinit = {
            source  = "opentofu/cloudinit"
            version = ">= 2.3.7"
        }
    }
}

locals {
    irole_name          = "irole-k3s-${var.nickname}_ssm-for-ec2"
    iprofile_name       = "iprofile-k3s-${var.nickname}_ssm-for-ec2"

    ec2_name            = "ec2-k3s-${var.nickname}"

    elb_name            = "elb-k3s-${var.nickname}"
    lport_name          = "lport-k3s-${var.nickname}"

    tgroup_name         = "tgroup-k3s-${var.nickname}"
    tgroup_name_6443    = "${local.tgroup_name}-6443"
    tgroup_name_80      = "${local.tgroup_name}-80"
    tgroup_name_443     = "${local.tgroup_name}-443"

    keypair_name        = "kp-${var.nickname}-k8s-node"
}

#########################################################
#    Keypairs to access EC2 instances (first option)    #
#########################################################
# Set up the AWS KeyPair
resource "aws_key_pair" "tls_key_k8s_node" {
    key_name    = local.keypair_name 
    public_key  = tls_private_key.tls_key_k8s_node.public_key_openssh
}
# Generate a TLS Private Key (Stored Locally)
resource "tls_private_key" "tls_key_k8s_node" {
    algorithm   = "RSA"
    rsa_bits    = 4096
}
# Output the private key to a local file for future use
resource "local_file" "private_key" {
    content         = tls_private_key.tls_key_k8s_node.private_key_pem
    filename        = "${path.module}/kp-${var.nickname}-k8s-node.pem"  # Path to store the private key
    file_permission = "0400"
}

#################################################################################
#    IAM role to use Systems Manager to access EC2 instances (second option)    #
#################################################################################
# Set up IAM Role
resource "aws_iam_role" "irole_ssm_ec2" {
    name = "${local.irole_name}"
    assume_role_policy = jsonencode({
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": [
                    "sts:AssumeRole"
                ],
                "Principal": {
                    "Service": [
                        "ec2.amazonaws.com"
                    ]
                }
            }
        ]
    })
}
# Attach the permission policy
resource "aws_iam_role_policy_attachment" "ipolicy_attachment_ssm_ec2" {
  role       = aws_iam_role.irole_ssm_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
# Set up EC2 instance profile for to assign the iam role
resource "aws_iam_instance_profile" "iprofile_ssm_ec2" {
  name = "${local.iprofile_name}"
  role = aws_iam_role.irole_ssm_ec2.name
}

#######################################
#    EC2 instances for K3S Cluster    #
#######################################
# Set up random strings for the purposes of appending them to node names
resource "random_string" "node_suffix" {
  count = var.node_count
  length  = 5 
  special = false 
  upper   = false 
  numeric  = true
}
# Initialize EC2 instances for the K3s cluster
resource "aws_instance" "k8s_node" {
    count                         = var.node_count
    ami                           = "ami-01b1eba85c1cd6a3d" 
    instance_type                 = "t4g.micro"
    subnet_id                     = var.subnet_ids[count.index % var.node_count] 
    key_name                      = aws_key_pair.tls_key_k8s_node.key_name 
    iam_instance_profile          = aws_iam_instance_profile.iprofile_ssm_ec2.name
    security_groups               = [aws_security_group.sg_main.id]  
    associate_public_ip_address   = true
    private_ip = count.index == 0 ? replace(var.cidr_blocks[count.index], "0/24", "100") : null

    user_data = templatefile("${path.module}/K3S_INSTALL.sh", {
        count_index = count.index
    })

    root_block_device {
        volume_size = 24 
        volume_type = "gp2" 
    }

    tags = {
        Name = "${local.ec2_name}-${random_string.node_suffix[count.index].result}"
    }
}

###########################################
#    Security Groups fro EC2 instances    #
###########################################
# Set up security groups 
resource "aws_security_group" "sg_main" {
    name          = "k8s_node_sg"
    description   = "K8s node secuirty group"
    vpc_id        = var.vpc_id

    tags = {
        Name = "k8s_node_sg"
    }

    # FUNCTIONAL : Port policies that can change based on project requirements
    # FUNCTIONAL : Ingress
    # Ingress : SSH : ADMIN
    ingress {
        description = "Allow SSH for Admin IP(s)"
        from_port   = 22
        to_port     = 22
        protocol    = "tcp"
        cidr_blocks = var.admin_ip_list
    }
    # Ingress : HTTP : ALL
    ingress {
        description = "Allow HTTP for End-Users"
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    # Ingress : HTTPS : ALL
    ingress {
        description = "Allow HTTPS for End-Users"
        from_port   = 443
        to_port     = 443
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    # FOUNDATIONAL : Egress
    # Egress : HTTP : ALL
    egress {
        description = "Allow HTTP for End-Users"
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    # Egress : HTTPS : ALL
    egress {
        description = "Allow HTTPS for End-Users"
        from_port   = 443
        to_port     = 443
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    # Egress : DNS : ALL
    egress {
        description = "Allow DNS queries"
        from_port   = 53
        to_port     = 53
        protocol    = "udp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    # FOUNDATIONAL : Port policies for Kubernetes to work (ONLY TOUCH THIS IF YOU KNOW WHAT YOU ARE DOING!)
    # FOUNDATIONAL : Ingress
    # Ingress : Kube-API : SELF
    ingress {
        description = "Allow Kube-API for instances"
        from_port   = 6443
        to_port     = 6443
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"] # TODO: Make it point to itself (as a security group)
    }
    # Ingress : ETCD (2379) : SELF
    ingress {
        description = "Allow etcd (2379) for instances"
        from_port   = 2379
        to_port     = 2379
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"] # TODO: Make it point to itself (as a security group)
    }
    # Ingress : ETCD (2380) : SELF
    ingress {
        description = "Allow etcd (2380) for instances"
        from_port   = 2380
        to_port     = 2380
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"] # TODO: Make it point to itself (as a security group)
    }
    # Ingress : FLANNEL : SELF
    ingress {
        description = "Allow Flannel for instances"
        from_port   = 8472
        to_port     = 8472
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"] # TODO: Make it point to itself (as a security group)
    }
    # Ingress : KUBELET : SELF
    ingress {
        description = "Allow Flannel for instances"
        from_port   = 10250
        to_port     = 10250
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"] # TODO: Make it point to itself (as a security group)
    }
    # FOUNDATIONAL : Egress
    # Egress : Kube-API : SELF
    egress {
        description = "Allow Kube-API for instances"
        from_port   = 6443
        to_port     = 6443
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"] # TODO: Make it point to itself (as a security group)
    }
    # Egress : ETCD (2379) : SELF
    egress {
        description = "Allow etcd (2379) for instances"
        from_port   = 2379
        to_port     = 2379
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"] # TODO: Make it point to itself (as a security group)
    }
    # Egress : ETCD (2380) : SELF
    egress {
        description = "Allow etcd (2380) for instances"
        from_port   = 2380
        to_port     = 2380
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"] # TODO: Make it point to itself (as a security group)
    }
    # Egress : FLANNEL : SELF
    egress {
        description = "Allow Flannel for instances"
        from_port   = 8472
        to_port     = 8472
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"] # TODO: Make it point to itself (as a security group)
    }
    # Egress : KUBELET : SELF
    egress {
        description = "Allow Flannel for instances"
        from_port   = 10250
        to_port     = 10250
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"] # TODO: Make it point to itself (as a security group)
    }

}

###############################################
#    Elastic Load Balancer for K3s cluster    #
###############################################
# Create a application load balancer
resource "aws_lb" "elb_main" {
    name               = "${local.elb_name}"
    internal           = false
    load_balancer_type = "network"
    security_groups    = [aws_security_group.sg_main.id]
    subnets            = [for subnet_id in var.subnet_ids : subnet_id ] # <-- Connect this up

    tags = {
        Name = "${local.elb_name}"
    }
}

# # Create a load balancer target group (port: 6443)
# resource "aws_lb_target_group" "tgroup_6443" {
#     name     = "${local.tgroup_name_6443}"
#     port     = 6443
#     protocol = "TCP"
#     vpc_id   = var.vpc_id
#     tags = {
#         Name = "${local.tgroup_name_6443}"
#     }
# }
# # Attach instances to target group (port: 6443)
# resource "aws_lb_target_group_attachment" "tgroup_attachment_6443" {
#     count = var.node_count
#     target_group_arn = aws_lb_target_group.tgroup_6443.arn
#     target_id        = aws_instance.k8s_node[count.index].id
#     port             = 6443
# }
# # Add listener to load balancer (port: 6443)
# resource "aws_lb_listener" "anb_listener_main_6443" {
#     load_balancer_arn = aws_lb.elb_main.arn
#     port              = "6443"
#     protocol          = "TCP"
#     default_action {
#         type             = "forward"
#         target_group_arn = aws_lb_target_group.tgroup_6443.arn
#     }
# }

# Create a load balancer target group (port: 80)
resource "aws_lb_target_group" "tgroup_80" {
    name     = "${local.tgroup_name_80}"
    port     = 80 # 30850 # Traefik port that represents port 80
    protocol = "TCP"
    vpc_id   = var.vpc_id
    tags = {
        Name = "${local.tgroup_name_80}"
    }
}
# Attach instances to target group (port: 80)
resource "aws_lb_target_group_attachment" "tgroup_attachment_80" {
    count = var.node_count
    target_group_arn = aws_lb_target_group.tgroup_80.arn
    target_id        = aws_instance.k8s_node[count.index].id
    port             = 80 # 30850 # Traefik port that represents port 80
}
# Add listener to load balancer (port: 80)
resource "aws_lb_listener" "anb_listener_main_80" {
    load_balancer_arn = aws_lb.elb_main.arn
    port              = "80"
    protocol          = "TCP"
    default_action {
        type             = "forward"
        target_group_arn = aws_lb_target_group.tgroup_80.arn
    }
}

# Create a load balancer target group (port: 443)
resource "aws_lb_target_group" "tgroup_443" {
    name     = "${local.tgroup_name_443}"
    port     = 443 # 30764 # Traefik port that represents port 443
    protocol = "TCP"
    vpc_id   = var.vpc_id
    tags = {
        Name = "${local.tgroup_name_443}"
    }
}
# Attach instances to target group (port: 443)
resource "aws_lb_target_group_attachment" "tgroup_attachment_443" {
    count = var.node_count
    target_group_arn = aws_lb_target_group.tgroup_443.arn
    target_id        = aws_instance.k8s_node[count.index].id
    port             = 443 # 30764 # Traefik port that represents port 443
}
# Add listener to load balancer (port: 443)
resource "aws_lb_listener" "anb_listener_main_443" {
    load_balancer_arn = aws_lb.elb_main.arn
    port              = "443"
    protocol          = "TCP"
    default_action {
        type             = "forward"
        target_group_arn = aws_lb_target_group.tgroup_443.arn
    }
}


