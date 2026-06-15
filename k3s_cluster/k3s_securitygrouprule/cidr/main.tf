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

  # Flatten to one rule per (direction, address-family, cidr). The new
  # aws_vpc_security_group_*_rule resources take a single CIDR each, so we
  # fan the caller's CIDR lists out here and keep the list-based interface.
  rules = merge(
    {
      for pair in setproduct(local.type_list, var.cidr_blocks) :
      "${pair[0]}:ipv4:${pair[1]}" => { type = pair[0], cidr_ipv4 = pair[1], cidr_ipv6 = null }
    },
    {
      for pair in setproduct(local.type_list, var.ipv6_cidr_blocks) :
      "${pair[0]}:ipv6:${pair[1]}" => { type = pair[0], cidr_ipv4 = null, cidr_ipv6 = pair[1] }
    },
  )

  ingress_rules = { for k, v in local.rules : k => v if v.type == "ingress" }
  egress_rules  = { for k, v in local.rules : k => v if v.type == "egress" }
}

# Create security group rules. These track each rule by its AWS-assigned
# security_group_rule_id, so a manually edited rule is corrected in place on
# apply instead of being duplicated.
resource "aws_vpc_security_group_ingress_rule" "sgr" {
  for_each          = local.ingress_rules
  security_group_id = var.security_group_id
  ip_protocol       = var.protocol
  from_port         = local.is_all_protocol ? null : local.from_port
  to_port           = local.is_all_protocol ? null : local.to_port
  cidr_ipv4         = each.value.cidr_ipv4
  cidr_ipv6         = each.value.cidr_ipv6
  description       = "${var.description} (ingress : ${var.protocol} : ${local.from_port} to ${local.to_port})"
}

resource "aws_vpc_security_group_egress_rule" "sgr" {
  for_each          = local.egress_rules
  security_group_id = var.security_group_id
  ip_protocol       = var.protocol
  from_port         = local.is_all_protocol ? null : local.from_port
  to_port           = local.is_all_protocol ? null : local.to_port
  cidr_ipv4         = each.value.cidr_ipv4
  cidr_ipv6         = each.value.cidr_ipv6
  description       = "${var.description} (egress : ${var.protocol} : ${local.from_port} to ${local.to_port})"
}
