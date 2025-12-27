variable "port" {
    description = "The override for both 'from_port' and 'to_port' variable"
    type        = number
    default     = null
}

variable "from_port" {
    description = "The starting port of the security group rule"
    type        = number
    default     = null

    validation {
        condition       = var.port != null || var.from_port != null
        error_message   = "from_port is not set (while the override of 'port' variable is not set as well)"
    }
}

variable "to_port" {
    description = "The ending port of the security group rule"
    type        = number
    default     = null

    validation {
        condition       = var.port != null || var.to_port != null
        error_message   = "to_port is not set (while the override of 'port' variable is not set as well)"
    }
}

variable "protocol" {
    description = "The protocol of the security group rule (e.g. tcp, udp)"
    type        = string
}

variable "type" {
    description = "The type of the security group rule (ingress, egress, both)"
    type        = string

    validation {
        condition     = contains(["ingress", "egress", "both"], var.type)
        error_message = "type must be ingress, egress, or both"
    }
}

variable "security_group_id" {
    description = "The ID of the security group to apply the rule to"
    type        = string
}

variable "description" {
    description = "The description of the security group rule"
    type        = string
    default     = ""
}

variable "cidr_blocks" {
    description = "The list of CIDR blocks for the security group rule"
    type        = list(string)
    default     = []
}

variable "ipv6_cidr_blocks" {
    description = "The list of IPv6 CIDR blocks for the security group rule"
    type        = list(string)
    default     = []
}
