#################################################################################
#    IAM role to use Systems Manager to access EC2 instances (second option)    #
#################################################################################
# Set up EC2 IAM instance profile to use SSM 
# USAGE: This will be applied onto EC2 instances
resource "aws_iam_instance_profile" "iprofile_ssm_ec2" {
  name = "${local.iprofile_name}"
  role = aws_iam_role.irole_ssm_ec2.name
}
# Set up IAM Role
resource "aws_iam_role" "irole_ssm_ec2" {
    name = "${local.irole_name}"
    assume_role_policy = jsonencode({
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": [
                    "sts:AssumeRole"
                ],
                "Principal": {
                    "Service": [
                        "ec2.amazonaws.com"
                    ]
                }
            }
        ]
    })
}
# Attach the permission policy
resource "aws_iam_role_policy_attachment" "ipolicy_attachment_ssm_ec2" {
  role       = aws_iam_role.irole_ssm_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
