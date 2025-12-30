########################################
#    IAM Role : K3s Cluster EC2 Node   #
########################################
# Establish IAM Instance Profile (EC2 Node)
resource "aws_iam_instance_profile" "iprofile_ec2" {
    name = local.iprofile_name
    role = aws_iam_role.irole_ec2.name

    tags = {
        Name     = local.iprofile_name
        Nickname = var.nickname
    }
}

# Establish IAM role (Establish role for EC2 instances ONLY)
resource "aws_iam_role" "irole_ec2" {
    name               = local.irole_name
    assume_role_policy = data.aws_iam_policy_document.assume_role_ec2.json

    tags = {
        Name     = local.irole_name
        Nickname = var.nickname
    }
}

# Setup policy document (Only allow EC2 resources to be able to assume this role)
data "aws_iam_policy_document" "assume_role_ec2" {
    statement {
        effect  = "Allow"
        actions = ["sts:AssumeRole"]

        principals {
            type        = "Service"
            identifiers = ["ec2.amazonaws.com"]
        }
    }
}

###########################################
#    IAM Policy : Systems Manager (SSM)   #
###########################################
# Attach permission policy (least-privilege policy for accessing EC2 via SSM interface)
resource "aws_iam_role_policy_attachment" "ssm_ec2" {
  role       = aws_iam_role.irole_ec2.name
  # Use pre-existing policy from AWS
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

#################################################
#    IAM Policy : K3S Token Parameter Storage   #
#################################################
# Attach permission policy (least-privilege policy for token paramstore)
resource "aws_iam_role_policy_attachment" "k3s_token_paramstore" {
    role       = aws_iam_role.irole_ec2.name
    policy_arn = aws_iam_policy.k3s_token_paramstore.arn
}

#
resource "aws_iam_policy" "k3s_token_paramstore" {
    name   = local.ipolicy_k3s_pstore_name
    policy = data.aws_iam_policy_document.k3s_token_paramstore.json
}

data "aws_iam_policy_document" "k3s_token_paramstore" {
    statement {
        actions = [
            "ssm:GetParameter",
            "ssm:PutParameter"
        ]
        resources = [
            "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${local.account_id}:parameter/simplek3s/${var.nickname}/k3s-token"
        ]
    }
}

#############################################
#    IAM Policy : S3 Bootstrap Read-Only    #
#############################################
# Attach permission policy (least-privilege policy for S3 bootstrap reads)
resource "aws_iam_role_policy_attachment" "bootstrap_read" {
    role       = aws_iam_role.irole_ec2.name
    policy_arn = aws_iam_policy.bootstrap_read.arn
}

# Establish IAM Policy using document
resource "aws_iam_policy" "bootstrap_read" {
    name   = local.ipolicy_s3_bstrap_name
    policy = data.aws_iam_policy_document.bootstrap_read.json
}

# Setup policy document
data "aws_iam_policy_document" "bootstrap_read" {
    statement {
        effect  = "Allow"
        actions = ["s3:GetObject"]
        resources = [
            "arn:${data.aws_partition.current.partition}:s3:::${local.s3_bstrap_name}/bootstrap/*"
        ]
    }
}
