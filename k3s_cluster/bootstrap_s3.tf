##############################################
#    Bootstrapping (Setup After Creation)    #
##############################################
# How it works: ...
resource "aws_ssm_parameter" "secret" {
    name        = "/simplek3s/${var.nickname}/k3s-token"
    description = "The K3s token - This is set on runtime"
    type        = "SecureString"
    value       = local.uninitialized # Sets the value to a preset uninitialized value

    tags = {
        Name        = local.pstore_k3s_token_name
        Nickname    = var.nickname
    }

    lifecycle {
        ignore_changes = [
            value # This is expected to change, so we ignore it
        ]
    }
}

###################################
#    S3 Files : Bootstrapping     #
###################################
# plan-time checks
resource "terraform_data" "bootstrap_files_check" {
    input = {
        k3s_sha  = filesha256(local.k3s_install_path)
        trf_sha  = filesha256(local.traefik_cfg_tmpl_path)
    }
}

# Module-level Bootstrapping (This will be executed before everything else!)
resource "aws_s3_object" "k3s_install" {
    bucket = aws_s3_bucket.bootstrap.id
    key    = "${local.s3_bstrap_key_root}/K3S_INSTALL.sh"
    source = local.k3s_install_path
}
resource "aws_s3_object" "traefik_cfg_tmpl" {
    bucket = aws_s3_bucket.bootstrap.id
    key    = "${local.s3_bstrap_key_root}/manifests/traefik-config.yaml.tmpl"
    source = local.traefik_cfg_tmpl_path
}

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
