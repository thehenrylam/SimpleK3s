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

# AWS CLI Version
variable "aws_cli_version" {
  description = "The AWS CLI v2 version to install on each EC2 node"
  type        = string
  default     = "2.34.63"
}

# SSM Agent Version
variable "ssm_agent_version" {
  description = "The amazon-ssm-agent version to install on each EC2 node"
  type        = string
  default     = "3.3.4515.0"
}

# Default EC2 AMI Name (Debian 13 ARM64)
# Pinned to an exact build so `tofu plan` stays idempotent: a newly published
# Debian AMI no longer resolves as "most_recent" and forces node replacement.
# The name is resolved to the correct per-region AMI ID by data.aws_ami.default
# (see cluster_ec2.tf), so it stays portable across regions. Bump this default
# deliberately to roll nodes onto a newer image.
variable "ec2_ami_name" {
  description = "Exact Debian 13 ARM64 AMI name used as the default node image (resolved to a per-region AMI ID). Pinned for plan idempotency."
  type        = string
  default     = "debian-13-arm64-20260601-2496"
}

# K3s Specific Config: K3s Version
variable "k3s_version" {
  description = "The K3s version to install across the cluster (control plane, agent nodes, and Karpenter-provisioned nodes)"
  type        = string
  default     = "v1.35.1+k3s1"
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

variable "subnet_ids" {
  description = "The subnet ids that EC2 instance will use"
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "The subnet ids must contain at least 1 subnet id"
  }
}

variable "controlplane" {
  description = "The control plane settings"
  type = object({
    node_count                     = optional(number)
    ec2_ami_id                     = optional(string)
    ec2_instance_type              = optional(string)
    ec2_swapfile_size              = optional(string)
    ebs_volume_size                = optional(number)
    ebs_volume_type                = optional(string)
    controller_private_ip_override = optional(string)
  })
  default = {}
}

variable "agentplane" {
  description = "The agent plane settings"
  type = object({
    node_count        = optional(number)
    ec2_ami_id        = optional(string)
    ec2_instance_type = optional(string)
    ec2_swapfile_size = optional(string)
    ebs_volume_size   = optional(number)
    ebs_volume_type   = optional(string)
  })
  default = {}
}

# Pre-built subsystems
variable "subsystems" {
  description = "Pre-built subsystems (Modify underlying cluster behavior)"
  type = object({
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
    karpenter = optional(object({
      version                = optional(string)
      ami_id                 = optional(string)
      k3s_version            = optional(string)
      capacity_type          = optional(string)
      arch                   = optional(string)
      instance_categories    = optional(list(string))
      instance_generation_gt = optional(number)
      cpu_limit              = optional(string)
      memory_limit           = optional(string)
      consolidate_after      = optional(string)
    }))
  })
  default = {}
}

# Pre-built applications
variable "applications" {
  description = "Pre-built applications (For easy setups)"
  type = object({
    argocd = optional(object({
      version           = optional(string)
      pstore_idp_config = string
      domain_name       = string
    }))
    monitoring = optional(object({
      version           = optional(string)
      pstore_idp_config = string
      domain_name       = string
    }))
  })
  default = {}
}
