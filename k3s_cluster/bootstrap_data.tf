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

    depends_on = [
        local_file.simplek3s_env
    ]
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

resource "local_file" "simplek3s_env" {
    content  = templatefile("${local.simplek3s_path}.tmpl", {
        bootstrap_dir           = local.bstrap_dir,
        nickname                = var.nickname,
        aws_region              = var.aws_region,
        controller_host         = local.controller_host,
        swapfile_alloc_amt      = var.ec2_swapfile_size,
        nodeport_http           = var.k3s_nodeport_traefik_http,
        nodeport_https          = var.k3s_nodeport_traefik_https,
        s3_bucket_name          = local.s3_bstrap_name
        s3key_simplek3s_env     = "${local.s3_bstrap_key_root}/simplek3s.env",
        s3key_k3s_install       = "${local.s3_bstrap_key_root}/K3S_INSTALL.sh",
        s3key_traefik_cfg_tmpl  = "${local.s3_bstrap_key_root}/manifests/traefik-config.yaml.tmpl",
    })
    filename = local.simplek3s_path
}
resource "aws_s3_object" "simplek3s_env" {
    bucket = aws_s3_bucket.bootstrap.id
    key    = "${local.s3_bstrap_key_root}/simplek3s.env"
    source = local.simplek3s_path

    depends_on = [
        local_file.simplek3s_env
    ]
}
