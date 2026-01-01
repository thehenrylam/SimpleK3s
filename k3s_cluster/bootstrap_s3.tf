#############################
#    S3 : Bootstrapping     #
#############################
# Initialize s3 bucket to set up bootstrap configs
resource "aws_s3_bucket" "bootstrap" {
    bucket = local.s3_bstrap_name

    tags = {
        Name        = local.s3_bstrap_name
        Nickname    = var.nickname
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
