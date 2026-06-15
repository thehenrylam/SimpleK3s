output "security_group_rule_ids" {
  description = "The IDs of the security group rules created"
  value = concat(
    [for r in aws_vpc_security_group_ingress_rule.sgr : r.security_group_rule_id],
    [for r in aws_vpc_security_group_egress_rule.sgr : r.security_group_rule_id],
  )
}
