locals {
  # Naming conventions for Thanos-related resources
  s3_thanos_name      = "s3-${local.module_name}-thanos"
  ipolicy_thanos_name = "ipolicy-${local.module_name}_thanos"

  # Thanos is a built-in part of the monitoring app: when monitoring is enabled,
  # Prometheus ships TSDB blocks to this bucket and the Store/Querier/Compactor
  # read from it. There is intentionally no separate opt-in toggle.
  thanos_enabled = var.applications.monitoring != null
}

#########################################
#    S3 : Thanos Metrics Bucket         #
#########################################
resource "aws_s3_bucket" "thanos" {
  count         = local.thanos_enabled ? 1 : 0
  bucket        = local.s3_thanos_name
  force_destroy = true

  tags = {
    Name     = local.s3_thanos_name
    Nickname = var.nickname
  }
}

resource "aws_s3_bucket_versioning" "thanos" {
  count  = local.thanos_enabled ? 1 : 0
  bucket = aws_s3_bucket.thanos[0].id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "thanos" {
  count  = local.thanos_enabled ? 1 : 0
  bucket = aws_s3_bucket.thanos[0].id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "thanos" {
  count                   = local.thanos_enabled ? 1 : 0
  bucket                  = aws_s3_bucket.thanos[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

##############################################################
#    IAM Policy : Thanos (S3 read/write)                     #
#    Attached to the shared EC2 node role; the Thanos        #
#    sidecar/store/compactor pods reach S3 via the node      #
#    instance profile (no access keys), same as Longhorn.    #
##############################################################
data "aws_iam_policy_document" "thanos" {
  count = local.thanos_enabled ? 1 : 0
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
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${local.s3_thanos_name}/*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${local.s3_thanos_name}"]
  }
}

resource "aws_iam_policy" "thanos" {
  count  = local.thanos_enabled ? 1 : 0
  name   = local.ipolicy_thanos_name
  policy = data.aws_iam_policy_document.thanos[0].json
}

resource "aws_iam_role_policy_attachment" "thanos" {
  count      = local.thanos_enabled ? 1 : 0
  role       = aws_iam_role.irole_ec2.name
  policy_arn = aws_iam_policy.thanos[0].arn
}
