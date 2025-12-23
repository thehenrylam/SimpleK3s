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

# project name 
variable "project_name" {
  type        = string
  default     = "k3s_test"
}
# region 
variable "region" {
  type        = string
  default     = "us-east-1"
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
