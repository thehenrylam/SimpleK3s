locals {
    # Translate var.type's input into a list of security group types to create
    type_list = var.type == "both" ? ["ingress", "egress"] : [var.type]

    # Determine from_port and to_port (use var.port as an override)
    from_port = coalesce(var.port, var.from_port)
    to_port   = coalesce(var.port, var.to_port)
}

# Create security group rules
resource "aws_security_group_rule" "sgr" {
    count                    = length(local.type_list)
    type                     = local.type_list[count.index]
    from_port                = local.from_port
    to_port                  = local.to_port
    protocol                 = var.protocol
    security_group_id        = var.security_group_id
    description              = "${var.description} (${local.type_list[count.index]} : ${var.protocol} : ${local.from_port} to ${local.to_port})"
    # Implied from the module's purpose
    self                     = true
}
