#############################
#    S3 : Bootstrapping     #
#############################
# Initialize s3 bucket to set up bootstrap configs
resource "aws_s3_bucket" "bootstrap" {
  bucket        = local.s3_bstrap_name
  force_destroy = true

  tags = {
    Name     = local.s3_bstrap_name
    Nickname = var.nickname
  }
}

# Make sure s3 bucket has versioning enabled
resource "aws_s3_bucket_versioning" "bootstrap" {
  bucket = aws_s3_bucket.bootstrap.id
  versioning_configuration { status = "Enabled" }
}

# Make sure encryption is ON
resource "aws_s3_bucket_server_side_encryption_configuration" "bootstrap" {
  bucket = aws_s3_bucket.bootstrap.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# Restrict bucket access
resource "aws_s3_bucket_public_access_block" "bootstrap" {
  bucket                  = aws_s3_bucket.bootstrap.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

##################################################
#  ORDERING : Bucket configs BEFORE object writes #
##################################################
# Object writes must be ordered after ALL of the bucket's companion configs.
#
# The three resources above reference only aws_s3_bucket.bootstrap, so they are
# siblings in the graph with no edges between them or to the object writes. They
# READ like a sequence in this file but compile to a fan-out, which lets Terraform
# upload objects into the bucket while the companions are still being applied:
#
#   - versioning: S3 documents a propagation delay when versioning is first
#     enabled. A PutObject issued inside that window succeeds, but the provider's
#     follow-up read-back can 404 ("couldn't find resource"), failing the apply on
#     an object that is actually present and correct. Hit on a fresh build in
#     August 2026 (app_argocd.sh); only reproducible on a from-scratch bucket,
#     since versioning is created exactly once per bucket lifetime.
#   - server-side encryption: sets DEFAULT encryption, which applies only to
#     objects written AFTER it exists and does NOT retroactively encrypt earlier
#     writes. Objects that win this race land unencrypted at rest, silently — no
#     error, no log line.
#   - public access block: same ordering class.
#
# All three arguments below evaluate to the same bucket name; the value is
# incidental. Referencing them is what creates the dependency edges. Note that
# Terraform builds edges from the reference itself, not from whether the value is
# known at plan time, so this orders the apply even though the name is static.
locals {
  s3_bstrap_bucket_id = coalesce(
    aws_s3_bucket_versioning.bootstrap.bucket,
    aws_s3_bucket_server_side_encryption_configuration.bootstrap.bucket,
    aws_s3_bucket_public_access_block.bootstrap.bucket,
  )
}
