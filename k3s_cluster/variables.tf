variable "nickname" {
    description = "The nickname of the module"
    type        = string
}

variable "vpc_id" {
    description = "The vpc id that the module will reside in"
    type        = string
}

variable "subnet_ids" {
    description = "The subnet ids that EC2 instance will use"
    type        = list(string)
}

# node count
variable "node_count" {
  type        = number
  default     = 1
}
# cidr blocks
variable "cidr_blocks" {
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24", "10.0.4.0/24"] 
}

variable "admin_ip_list" {
    type      = list(string)
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

variable "k3s_token" {
    description = "The K3s cluster token for node authentication"
    type        = string
}

variable "ec2_ami_id" {
    description = "The AMI ID for the EC2 instances"
    type        = string
    default     = "ami-01b1eba85c1cd6a3d" # debian-13-arm64-20250814-2204 (US East 1)
}

variable "ec2_instance_type" {
    description = "The EC2 instance type for K3s nodes"
    type        = string
    default     = "t4g.micro"
}

variable "ec2_swapfile_size" {
    description = "The swapfile size for EC2 instances"
    type        = string
    default     = "2G"
}

variable "ec2_ebs_volume_size" {
    description = "The EBS volume size for EC2 instances"
    type        = number
    default     = 24
}

variable "ec2_ebs_volume_type" {
    description = "The EBS volume type for EC2 instances"
    type        = string
    default     = "gp2"
}
