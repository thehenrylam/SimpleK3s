variable "nickname" {
    description = "The nickname of the module"
    type        = string
    default     = "simplek3s"
}

variable "aws_region" {
    description = "The aws region that the resources will deploy on (should be the same as used in the VPC)"
    type        = string
}

variable "vpc_id" {
    description = "The vpc id that the module will reside in"
    type        = string
}

###########################################
#   Account ID (to set IAM permissions)   #
###########################################
variable "account_id" {
    description = "The account ID. Used to help set IAM permissions for least-priviledged setups"
    type        = string
    default     = null
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

variable "controlplane" {
    description = "The control plane settings"
    type        = object({
        node_count          = optional(number)
        ec2_ami_id          = optional(string)
        ec2_instance_type   = optional(string)
        ec2_swapfile_size   = optional(string)
        ebs_volume_size     = optional(number)
        ebs_volume_type     = optional(string)
        subnet_ids          = list(string)
        controller_private_ip_override = optional(string)
    })
}

variable "agentplane" {
    description = "The control plane settings"
    type        = object({
        node_count          = optional(number)
        ec2_ami_id          = optional(string)
        ec2_instance_type   = optional(string)
        ec2_swapfile_size   = optional(string)
        ebs_volume_size     = optional(number)
        ebs_volume_type     = optional(string)
        subnet_ids          = list(string)
    })
}

# Pre-built subsystems
variable "subsystems" {
    description = "Pre-built subsystems (Modify underlying cluster behavior)"
    type        = object({
        traefik = optional(object({
            version = optional(string)
        }))
        kyverno = optional(object({
            version = optional(string)
        }))
        external-secrets = optional(object({
            version = optional(string)
        }))
        descheduler = optional(object({
            version = optional(string)
        }))
    })
    default = {}
}

# Pre-built applications
variable "applications" {
    description = "Pre-built applications (For easy setups)"
    type        = object({
        argocd  = optional(object({
            version = optional(string)
            pstore_idp_config = string
            domain_name = string
        }))
        monitoring = optional(object({
            version = optional(string)
            pstore_idp_config = string
            domain_name = string
        }))
    })
    default     = {}
}
