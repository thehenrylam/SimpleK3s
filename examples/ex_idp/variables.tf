variable "nickname" {
    description = "The nickname of the module"
    type        = string
    default     = "idp-standalone"
}

variable "aws_region" {
    description = "The aws region that the resources will deploy on (should be the same as used in the VPC)"
    type        = string
}

variable "dns" {
    description = "The DNS data that end-users will use to access the cluster (example.com)"
    type        = object({
        basename    = string
        prefix      = optional(string)
    })
}
