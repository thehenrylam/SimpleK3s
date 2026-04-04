#########################################
# Karpenter IAM (v1 pragmatic bootstrap)
#########################################

data "aws_partition" "current" {}

locals {
    karpenter_controller_policy_name    = "ipolicy-${local.module_name}_karpenter-controller"
    karpenter_node_role_name            = "irole-${local.module_name}_karpenter-node"
    karpenter_node_profile_name         = "iprofile-${local.module_name}_karpenter-node"
    karpenter_node_policy_name          = "ipolicy-${local.module_name}_karpenter-node"
    karpenter_node_s3_bstrap_obj_name   = "ipolicy-${local.module_name}_karpenter-node_s3obj"
    karpenter_node_s3_bstrap_bkt_name   = "ipolicy-${local.module_name}_karpenter-node_s3bkt"
}

############################
# Karpenter worker IAM role
############################
data "aws_iam_policy_document" "karpenter_node_assume_role" {
    statement {
        effect = "Allow"

        principals {
            type        = "Service"
            identifiers = ["ec2.amazonaws.com"]
        }

        actions = ["sts:AssumeRole"]
    }
}

resource "aws_iam_role" "karpenter_node" {
    name               = local.karpenter_node_role_name
    assume_role_policy = data.aws_iam_policy_document.karpenter_node_assume_role.json

    tags = {
        Name     = local.karpenter_node_role_name
        Nickname = var.nickname
        Module   = local.module_name
    }
}

resource "aws_iam_instance_profile" "karpenter_node" {
    name = local.karpenter_node_profile_name
    role = aws_iam_role.karpenter_node.name

    tags = {
        Name     = local.karpenter_node_profile_name
        Nickname = var.nickname
        Module   = local.module_name
    }
}

data "aws_iam_policy_document" "karpenter_node" {
    statement {
        sid    = "ReadK3sJoinToken"
        effect = "Allow"
        actions = [
            "ssm:GetParameter"
        ]
        resources = [
            "arn:${data.aws_partition.current.partition}:ssm:${var.iam_config.region}:${var.iam_config.account_id}:parameter${local.settings.token_ssm_name}"
        ]
    }
}

resource "aws_iam_policy" "karpenter_node" {
    name   = local.karpenter_node_policy_name
    policy = data.aws_iam_policy_document.karpenter_node.json

    tags = {
        Name     = local.karpenter_node_policy_name
        Nickname = var.nickname
        Module   = local.module_name
    }
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ssm_core" {
    role       = aws_iam_role.karpenter_node.name
    policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_custom" {
    role       = aws_iam_role.karpenter_node.name
    policy_arn = aws_iam_policy.karpenter_node.arn
}

###########################################
# Karpenter controller AWS API permissions
# Pragmatic v1: attach to existing EC2 role
###########################################
resource "aws_iam_role_policy_attachment" "karpenter_controller" {
    role       = var.iam_config.role_name
    policy_arn = aws_iam_policy.karpenter_controller.arn
}

resource "aws_iam_policy" "karpenter_controller" {
    name   = local.karpenter_controller_policy_name
    policy = data.aws_iam_policy_document.karpenter_controller.json

    tags = {
        Name     = local.karpenter_controller_policy_name
        Nickname = var.nickname
        Module   = local.module_name
    }
}

data "aws_iam_policy_document" "karpenter_controller" {
    statement {
        sid    = "KarpenterEC2BroadActions"
        effect = "Allow"
        actions = [
            "ec2:*",
            "pricing:GetProducts"
        ]
        resources = ["*"]
    }

    statement {
        sid    = "PassKarpenterWorkerRole"
        effect = "Allow"
        actions = [
            "iam:PassRole",
            "iam:GetInstanceProfile"
        ]
        resources = [
            aws_iam_role.karpenter_node.arn,
            "arn:${data.aws_partition.current.partition}:iam::${var.iam_config.account_id}:instance-profile/${aws_iam_instance_profile.karpenter_node.name}"
        ]
    }

    statement {
        sid    = "KarpenterInstanceProfileGC"
        effect = "Allow"
        actions = [
            "iam:ListInstanceProfiles",
            "iam:CreateInstanceProfile",
            "iam:DeleteInstanceProfile",
            "iam:AddRoleToInstanceProfile",
            "iam:RemoveRoleFromInstanceProfile",
            "iam:TagInstanceProfile"
        ]
        resources = [
            "arn:${data.aws_partition.current.partition}:iam::${var.iam_config.account_id}:instance-profile/karpenter/*"
        ]
    }
}

#############################################
#    IAM Policy : S3 Bootstrap Read-Only    #
#############################################
# Attach permission policy (least-privilege policy for S3 bootstrap reads)
resource "aws_iam_role_policy_attachment" "karpenter_s3_read" {
    role       = aws_iam_role.karpenter_node.name
    policy_arn = aws_iam_policy.karpenter_s3_read.arn
}

# Establish IAM Policy using document
resource "aws_iam_policy" "karpenter_s3_read" {
    name   = local.karpenter_node_s3_bstrap_obj_name
    policy = data.aws_iam_policy_document.karpenter_s3_read.json
}

# Setup policy document
data "aws_iam_policy_document" "karpenter_s3_read" {
    statement {
        effect  = "Allow"
        actions = ["s3:GetObject"]
        resources = [
            "arn:${data.aws_partition.current.partition}:s3:::${var.s3_config.id}/*"
        ]
    }
}

# Attach permission policy (least-privilege policy for S3 bootstrap reads)
resource "aws_iam_role_policy_attachment" "karpenter_s3_listbucket" {
    role       = aws_iam_role.karpenter_node.name
    policy_arn = aws_iam_policy.karpenter_s3_listbucket.arn
}

# Establish IAM Policy using document
resource "aws_iam_policy" "karpenter_s3_listbucket" {
    name   = local.karpenter_node_s3_bstrap_bkt_name
    policy = data.aws_iam_policy_document.karpenter_s3_listbucket.json
}

# Setup policy document
data "aws_iam_policy_document" "karpenter_s3_listbucket" {
    statement {
        effect  = "Allow"
        actions = ["s3:ListBucket"]
        resources = [
            "arn:${data.aws_partition.current.partition}:s3:::${var.s3_config.id}"
        ]
    }
}

