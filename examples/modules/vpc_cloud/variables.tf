variable "nickname" {
    description = "The deployment's identifier (nickname). Will be used to help name cloud assets."
    type        = string
}

variable "node_count" {
  type        = number
  default     = 1
}

variable "vpc_cidr_block" {
    description = "The CIDR block that the VPC will use"
    type = string
    validation {
        condition = provider::assert::cidrv4(var.vpc_cidr_block)
        error_message = "The vpc_cidr_block must be a valid IPv4 CIDR notation, e.g., 10.0.0.0/16."
    }
    default = "" 
}

variable "sbn_cidr_blocks" {
    description = "The CIDR blocks that the VPC will use"
    type = list(string)
    validation {
        condition = alltrue([ for cidr in var.sbn_cidr_blocks : provider::assert::cidrv4( cidr ) ])
        error_message = "The vpc_cidr_block must be a valid IPv4 CIDR notation, e.g., 10.0.0.0/16."
    }
    default = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24", "10.0.4.0/24"]
}

variable "sbn_availability_zones" {
    description = "The subnets that the instances will live in"
    type        = list(string)
    default     = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"] 
}

