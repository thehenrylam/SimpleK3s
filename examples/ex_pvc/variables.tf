variable "nickname" {
  description = "Cluster nickname — must match the nickname used in examples/ex_basic"
  type        = string
}

variable "aws_region" {
  description = "AWS region to create volumes in"
  type        = string
}

variable "pools" {
  description = "EBS volume pools for Longhorn. One volume per availability_zone entry is created per pool."
  type = list(object({
    name               = string
    availability_zones = list(string)
    volume_size_gb     = number
    iops               = optional(number, 3000) # gp3 baseline
    throughput         = optional(number, 125)  # gp3 baseline MB/s
  }))

  validation {
    condition     = length(var.pools) > 0
    error_message = "At least one pool must be defined."
  }

  validation {
    condition     = alltrue([for p in var.pools : length(p.availability_zones) > 0])
    error_message = "Each pool must specify at least one availability_zone."
  }

  validation {
    condition     = alltrue([for p in var.pools : p.volume_size_gb >= 10])
    error_message = "EBS volume size must be at least 10 GB."
  }
}
