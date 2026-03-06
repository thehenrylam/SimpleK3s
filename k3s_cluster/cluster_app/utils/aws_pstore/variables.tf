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

variable "uninitialized" {
    description = "The uninitialized value in case "
    type        = string
    default     = "__UNINITIALIZED__"
}

# The list of pstores that the root module will use
variable "pstore_data" {
    description = "The list of pstore data"
    type        = list(object({
        alias       = string
        name        = string
        desc        = string
        value       = optional(string)
        encrypted   = bool
        create      = bool
    }))
}

# Optional: IAM config (to help refine IAM settings)
variable "iam_config" {
    description = "The config of the iam (to help refine IAM settings)"
    type        = object({
        role_name   = string
        partition   = optional(string)
        region      = optional(string)
        account_id  = optional(string)
    })
}

# Tags to apply to resources
variable "tags" {
    type        = map(string)
    description = "Tags to apply to resources."
    default     = {}
}
