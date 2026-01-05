##############################################
#    Bootstrapping (Setup After Creation)    #
##############################################
# SSM Parameter: K3s Token
resource "aws_ssm_parameter" "k3s_token" {
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
    # Goal: Make sure that all of the files set within local.s3_files_key_src_path is present
    # Use the filepath directly if template is not set (i.e. null)
    # Otherwise, assume that the file is a templated file, so we add a ".tmpl" file extension
    count = length(local.s3_files_key_src_path)
    input = {
        sha_check = filesha256( 
            local.s3_files_key_src_path[ count.index ].template == null ?
            local.s3_files_key_src_path[ count.index ].src : 
            "${local.s3_files_key_src_path[ count.index ].src}.tmpl"
            
        )
    }
}

# Template and upload data files to S3 (default)
resource "aws_s3_object" "bootstrap_s3_obj_default" {
    count  = length(local.s3_files_key_src_path)
    bucket = aws_s3_bucket.bootstrap.id
    key    = local.s3_files_key_src_path[count.index].key
    source = local.s3_files_key_src_path[count.index].src

    # Allow templating to execute before the files are uploaded to s3 bucket 
    depends_on = [
        local_file.bootstrap_s3_obj_default_tmpl
    ]
}
resource "local_file" "bootstrap_s3_obj_default_tmpl" {
    for_each    = { for obj in local.s3_files_key_src_path : obj.src => obj.template if obj.template != null }
    content     = templatefile("${each.key}.tmpl", each.value)
    filename    = each.key
}
