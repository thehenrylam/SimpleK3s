output "security_group_rule_ids" {
    description = "The IDs of the security group rules created"
    value       = concat(
        aws_security_group_rule.sgr_self[*].id,
        aws_security_group_rule.sgr_security_group[*].id,
        aws_security_group_rule.sgr_cidr_blocks[*].id
    )
}
