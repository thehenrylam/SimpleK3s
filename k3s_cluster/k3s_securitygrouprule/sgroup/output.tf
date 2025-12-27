output "security_group_rule_ids" {
    description = "The IDs of the security group rules created"
    value       = aws_security_group_rule.sgr[*].id
}
