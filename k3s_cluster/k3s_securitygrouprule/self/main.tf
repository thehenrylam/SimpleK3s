terraform {
  required_version = "~> 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

locals {
  # Translate var.type's input into a list of security group types to create
  type_list = var.type == "both" ? ["ingress", "egress"] : [var.type]

  # Determine from_port and to_port (use var.port as an override)
  from_port = coalesce(var.port, var.from_port)
  to_port   = coalesce(var.port, var.to_port)

  # The single-rule resources do not accept port ranges for the "all" protocol
  is_all_protocol = var.protocol == "-1"

  create_ingress = contains(local.type_list, "ingress")
  create_egress  = contains(local.type_list, "egress")
}

# Create security group rules. These track each rule by its AWS-assigned
# security_group_rule_id, so a manually edited rule is corrected in place on
# apply instead of being duplicated.
# Self-reference: the rule references the same security group it lives in.
resource "aws_vpc_security_group_ingress_rule" "sgr" {
  count                        = local.create_ingress ? 1 : 0
  security_group_id            = var.security_group_id
  ip_protocol                  = var.protocol
  from_port                    = local.is_all_protocol ? null : local.from_port
  to_port                      = local.is_all_protocol ? null : local.to_port
  referenced_security_group_id = var.security_group_id
  description                  = "${var.description} (ingress : ${var.protocol} : ${local.from_port} to ${local.to_port})"
}

resource "aws_vpc_security_group_egress_rule" "sgr" {
  count                        = local.create_egress ? 1 : 0
  security_group_id            = var.security_group_id
  ip_protocol                  = var.protocol
  from_port                    = local.is_all_protocol ? null : local.from_port
  to_port                      = local.is_all_protocol ? null : local.to_port
  referenced_security_group_id = var.security_group_id
  description                  = "${var.description} (egress : ${var.protocol} : ${local.from_port} to ${local.to_port})"
}
