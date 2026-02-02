# AWS Region  
variable "aws_region" {
    description = "The AWS region to create resources in."
    type        = string
    default     = "us-east-1"
}

variable "nickname" {
    description = "The nickname of the K3s cluster"
    type        = string
    default     = "k3s-morticai"
}

variable "admin_ip_list" {
    description = "The list of admin IPs to allow SSH access into the individual hosts"
    type        = list(string)
}

variable "node_count" {
    description = "The number of nodes to deploy on the K3s cluster"
    type        = string
    default     = 2
}

variable "vpc_cidr_block" {
    description = "The VPC cidr block"
    type        = string
    default     = "10.0.0.0/16"
}

variable "sbn_cidr_blocks" {
    description = "The list of subnet cidr blocks"
    type        = list(string)
    default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24", "10.0.4.0/24"]
}

variable "sbn_availability_zones" {
    description = "The list of subnet availability zones"
    type        = list(string)
    default     = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
}

variable "dns" {
    description = "The DNS data that end-users will use to access the cluster (example.com)"
    type        = object({
        basename    = string
        prefix      = optional(string)
    })
}
