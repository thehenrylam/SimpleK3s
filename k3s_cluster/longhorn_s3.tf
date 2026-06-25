locals {
  # Naming conventions for Longhorn-related resources
  s3_longhorn_backup_name = "s3-${local.module_name}-longhorn-backup"
  ipolicy_longhorn_name   = "ipolicy-${local.module_name}_longhorn"

  # Derived flags
  longhorn_enabled = var.subsystems.longhorn != null
  longhorn_backup_enabled = local.longhorn_enabled && anytrue([
    for p in try(var.subsystems.longhorn.pools, []) : p.backup_s3_prefix != null
  ])
}

#########################################
#    S3 : Longhorn Backup Bucket        #
#########################################
resource "aws_s3_bucket" "longhorn_backup" {
  count         = local.longhorn_backup_enabled ? 1 : 0
  bucket        = local.s3_longhorn_backup_name
  force_destroy = true

  tags = {
    Name     = local.s3_longhorn_backup_name
    Nickname = var.nickname
  }
}

resource "aws_s3_bucket_versioning" "longhorn_backup" {
  count  = local.longhorn_backup_enabled ? 1 : 0
  bucket = aws_s3_bucket.longhorn_backup[0].id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "longhorn_backup" {
  count  = local.longhorn_backup_enabled ? 1 : 0
  bucket = aws_s3_bucket.longhorn_backup[0].id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "longhorn_backup" {
  count                   = local.longhorn_backup_enabled ? 1 : 0
  bucket                  = aws_s3_bucket.longhorn_backup[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

##############################################################
#    IAM Policy : Longhorn (EBS + SSM + S3 backup)          #
#    Consolidated into one policy to stay within the         #
#    10 managed-policies-per-role AWS quota.                 #
##############################################################

# Core permissions (always present when Longhorn is enabled)
data "aws_iam_policy_document" "longhorn_core" {
  # DescribeVolumes is read-only and needs no resource scoping
  statement {
    effect    = "Allow"
    actions   = ["ec2:DescribeVolumes"]
    resources = ["*"]
  }
  # AttachVolume: scoped to instances belonging to this cluster
  statement {
    effect  = "Allow"
    actions = ["ec2:AttachVolume"]
    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${local.account_id}:volume/*",
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${local.account_id}:instance/*"
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Nickname"
      values   = [var.nickname]
    }
  }
  # SSM: read EBS volume ID lists stored by the user's ex_pvc root.
  # Scoped to the exact parameter paths declared in each pool's ebs_volumes_pstore_name
  # rather than a fixed prefix, so this works regardless of where ex_pvc stores them.
  statement {
    effect  = "Allow"
    actions = ["ssm:GetParameter"]
    resources = [
      for p in try(var.subsystems.longhorn.pools, []) :
      "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${local.account_id}:parameter${p.ebs_volumes_pstore_name}"
    ]
  }
}

# Backup permissions (only when at least one pool enables backups)
data "aws_iam_policy_document" "longhorn_backup_perms" {
  count = local.longhorn_backup_enabled ? 1 : 0
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
      "s3:ListBucketMultipartUploads"
    ]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${local.s3_longhorn_backup_name}/*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${local.s3_longhorn_backup_name}"]
  }
}

# Merge core + optional backup into one document
data "aws_iam_policy_document" "longhorn" {
  count = local.longhorn_enabled ? 1 : 0
  source_policy_documents = compact([
    data.aws_iam_policy_document.longhorn_core.json,
    one(data.aws_iam_policy_document.longhorn_backup_perms[*].json),
  ])
}

resource "aws_iam_policy" "longhorn" {
  count  = local.longhorn_enabled ? 1 : 0
  name   = local.ipolicy_longhorn_name
  policy = data.aws_iam_policy_document.longhorn[0].json
}

resource "aws_iam_role_policy_attachment" "longhorn" {
  count      = local.longhorn_enabled ? 1 : 0
  role       = aws_iam_role.irole_ec2.name
  policy_arn = aws_iam_policy.longhorn[0].arn
}
