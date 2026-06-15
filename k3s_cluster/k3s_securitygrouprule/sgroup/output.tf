output "security_group_rule_ids" {
  description = "The IDs of the security group rules created"
  value = concat(
    aws_vpc_security_group_ingress_rule.sgr[*].security_group_rule_id,
    aws_vpc_security_group_egress_rule.sgr[*].security_group_rule_id,
  )
}
