# The nickname of the module
variable "nickname" {
    description = "The nickname of the module"
    type        = string
}

# The module name (used to specify certain components)
variable "module_name" {
    description = "The module name"
    type        = string
}

# The S3 bucket ID
variable "s3_bucket_id" {
    description = "The S3 bucket id"
    type        = string
}

# The S3 bucket data files that will be templated and uploaded
variable "s3obj_data" {
    description = "The S3 object data"
    type        = list(object({
        desc        = string
        key         = string
        src         = string
        template    = optional(string)
    }))
    default     = []
}

# Tags to apply to resources
variable "tags" {
    type        = map(string)
    description = "Tags to apply to resources."
    default     = {}
}
