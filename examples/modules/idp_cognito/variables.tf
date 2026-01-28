variable "nickname" {
    description = "The deployment's identifier (nickname). Will be used to help name cloud assets."
    type = string
}

variable "tags" {
    type        = map(string)
    description = "Tags to apply to resources."
    default     = {}
}

variable "callback_urls" {
    type        = list(string)
    description = "Allowed OAuth2 callback URLs for your apps (Argo CD/Jenkins/etc)."
}

variable "logout_urls" {
    type        = list(string)
    description = "Allowed logout URLs."
    default     = []
}

variable "supported_identity_providers" {
    type        = list(string)
    description = "Usually [\"COGNITO\"]. Add others if you later configure Google/SAML/etc."
    default     = ["COGNITO"]
}

variable "oauth_scopes" {
    type        = list(string)
    description = "OAuth scopes for the app client."
    default     = ["openid", "email", "profile"]
}

variable "group_names" {
    type        = list(string)
    description = "The list group names"
    default     = ["platform-admins"]
    validation {
        condition     = alltrue([for g in var.group_names : length(trimspace(g)) > 0])
        error_message = "group_names cannot contain empty/whitespace-only values"
    }
}

variable "users" {
    type        = list(
        object({
            username    = string
            group       = optional(string)
        })
    )
    description = "Users list (with group assignments). The username MUST be in an email format, and group must be set to null if it shouldn't be part of any groups"
    default     = []
    validation {
        condition = alltrue([
            for u in var.users : (
                # Email-ish check
                can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", u.username))
                &&
                # group must be null OR a valid group name from var.group_names
                (
                    u.group == null
                    || (
                        length(trim(u.group)) > 0
                        && contains(var.group_names, u.group)
                    )
                )
            )
        ])
        error_message = "Each users[*].username must be in email format. Each users[*].group must be null or exactly match one of var.group_names"
    }
}
