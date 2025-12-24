locals {
    type_list = var.type == "both" ? ["ingress", "egress"] : [var.type]
}

# Create security group rules
resource "aws_security_group_rule" "sgr" {
    count                    = length(local.type_list)
    type                     = local.type_list[count.index]
    from_port                = var.from_port
    to_port                  = var.to_port
    protocol                 = var.protocol
    self                     = var.self
    security_group_id        = var.security_group_id
    description              = "${var.description} (${local.type_list[count.index]} : ${var.protocol} : ${var.from_port} to ${var.to_port})"
}
