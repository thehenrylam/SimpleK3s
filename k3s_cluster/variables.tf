variable "nickname" {
    description = "The nickname of the module"
    type        = string
}

variable "aws_region" {
    description = "The aws region that the resources will deploy on (should be the same as used in the VPC)"
    type        = string
}

variable "vpc_id" {
    description = "The vpc id that the module will reside in"
    type        = string
}

variable "subnet_ids" {
    description = "The subnet ids that EC2 instance will use"
    type        = list(string)

    validation {
        condition     = length(var.subnet_ids) > 0
        error_message = "The subnet ids must contain at least 1 subnet id"
    }
}

# node count
variable "node_count" {
    description = "The number of nodes to deploy on the K3s cluster (highly recommended to have odd node count from Kubernetes recommendations)"
    type        = number
    default     = 3

    validation {
        condition     = var.node_count >= 1
        error_message = "The number of nodes MUST be equal or greater than 1"
    }
}

###########################################
#   Account ID (to set IAM permissions)   #
###########################################
variable "account_id" {
    description = "The account ID. Used to help set IAM permissions for least-priviledged setups"
    type        = string
    default     = null
}

#############################################
#   Networking (avoid fragile CIDR lists)   #
#############################################
# Which subnet the controller (node 0) should live in. Defaults to subnet_ids[0].
variable "controller_subnet_id" {
    description = "Subnet ID to place the controller node in. Must be one of subnet_ids from var.subnet_ids. If null, it defaults to subnet_ids[0]"
    type        = string
    default     = null

    validation {
        condition     = var.controller_subnet_id == null || contains(var.subnet_ids, var.controller_subnet_id)
        error_message = "controller_subnet_id must be null or one of the values in subnet_ids."
    }
}

# This is an override to explicitly set the controller private IP.
variable "controller_private_ip" {
    description = "Optional explicit private IP for the controller node. If null, computed via cidrhost()."
    type        = string
    default     = null
}

# This is a host number to use in the last octet of the controller private IP.
# By default we pick host #100 from the controller subnet (works for /16, /20, /24, etc).
variable "controller_private_ip_hostnum" {
    description = "Host number within the controller subnet to use for the controller private IP when controller_private_ip is null."
    type        = number
    default     = 100
}

variable "admin_ip_list" {
    description = "The list of admin IPs to allow SSH access into the individual hosts"
    type        = list(string)
}

# K3s Specific Config: Traefik NodePorts
variable "k3s_nodeport_traefik_http" {
    description = "The traefik nodeport representing the K3 pod HTTP port"
    type        = number
    default     = 30080
}
variable "k3s_nodeport_traefik_https" {
    description = "The traefik nodeport representing the K3 pod HTTPS port"
    type        = number
    default     = 30443
}

variable "ec2_ami_id" {
    description = "The AMI ID for the EC2 instances"
    type        = string
    default     = "ami-01b1eba85c1cd6a3d" # debian-13-arm64-20250814-2204 (US East 1)
}

variable "ec2_instance_type" {
    description = "The EC2 instance type for K3s nodes (Minimum size is t4g.small to mitigate control node flakiness)"
    type        = string
    default     = "t4g.small" 
}

variable "ec2_swapfile_size" {
    description = "The swapfile size for EC2 instances (default: 1G)"
    type        = string
    default     = "1G"
}

variable "ec2_ebs_volume_size" {
    description = "The EBS volume size for EC2 instances (default: 12)"
    type        = number
    default     = 12
}

variable "ec2_ebs_volume_type" {
    description = "The EBS volume type for EC2 instances (default: gp3)"
    type        = string
    default     = "gp3" # gp3 is favored since we are using small volumes while maintaining reliable performance
}
