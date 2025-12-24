variable "from_port" {
    description = "The starting port of the security group rule"
    type        = number
}

variable "to_port" {
    description = "The ending port of the security group rule"
    type        = number
}

variable "protocol" {
    description = "The protocol of the security group rule (e.g. tcp, udp)"
    type        = string
}

variable "type" {
    description = "The type of the security group rule (ingress, egress, both)"
    type        = string
}

variable "self" {
    description = "Whether the rule applies to the security group itself"
    type        = bool
    default     = false
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
