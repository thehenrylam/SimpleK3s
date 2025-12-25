locals {
    type_list = var.type == "both" ? ["ingress", "egress"] : [var.type]
}

# Create security group rules
resource "aws_security_group_rule" "sgr_self" {
    # If self is FALSE, don't create this resource (set count to 0)
    count                    = var.self == true ? length(local.type_list) : 0
    type                     = local.type_list[count.index]
    from_port                = var.from_port
    to_port                  = var.to_port
    protocol                 = var.protocol
    self                     = var.self
    security_group_id        = var.security_group_id
    description              = "${var.description} (${local.type_list[count.index]} : ${var.protocol} : ${var.from_port} to ${var.to_port})"
}

resource "aws_security_group_rule" "sgr_security_group" {
    # If source_security_group_id is EMPTY, don't create this resource (set count to 0)
    count                    = var.source_security_group_id != null ? length(local.type_list) : 0
    type                     = local.type_list[count.index]
    from_port                = var.from_port
    to_port                  = var.to_port
    protocol                 = var.protocol
    source_security_group_id = var.source_security_group_id
    security_group_id        = var.security_group_id
    description              = "${var.description} (${local.type_list[count.index]} : ${var.protocol} : ${var.from_port} to ${var.to_port})"
}

resource "aws_security_group_rule" "sgr_cidr_blocks" {
    # If cidr_blocks or ipv6_cidr_blocks are provided, create this resource
    count                    = length(var.cidr_blocks) > 0 || length(var.ipv6_cidr_blocks) > 0 ? length(local.type_list) : 0
    type                     = local.type_list[count.index]
    from_port                = var.from_port
    to_port                  = var.to_port
    protocol                 = var.protocol
    cidr_blocks              = var.cidr_blocks
    ipv6_cidr_blocks         = var.ipv6_cidr_blocks
    security_group_id        = var.security_group_id
    description              = "${var.description} (${local.type_list[count.index]} : ${var.protocol} : ${var.from_port} to ${var.to_port})"
}
