##############################################
#    Bootstrapping (Setup After Creation)    #
##############################################
# SSM Parameter: Convert parameter store data into ssm params
# Dynamic - Value can change without having Terraform report it
resource "aws_ssm_parameter" "ssm_params_dynamic" {
    count       = length(local.pstore_data)

    description = local.pstore_data[ count.index ].desc
    type        = local.pstore_data[ count.index ].type    
    name        = local.pstore_data[ count.index ].key
    value       = local.pstore_data[ count.index ].val

    tags = {
        Name        = local.pstore_data[ count.index ].name
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
    # Goal: Make sure that all of the files set within local.s3obj_data is present
    # Use the filepath directly if template is not set (i.e. null)
    # Otherwise, assume that the file is a templated file, so we add a ".tmpl" file extension
    count = length(local.s3obj_data)
    input = {
        sha_check = filesha256( 
            local.s3obj_data[ count.index ].template == null ?
            local.s3obj_data[ count.index ].src : 
            "${local.s3obj_data[ count.index ].src}.tmpl"
            
        )
    }
}

# Template and upload data files to S3 (default)
resource "aws_s3_object" "bootstrap_s3_obj_default" {
    count  = length(local.s3obj_data)
    bucket = aws_s3_bucket.bootstrap.id
    key    = local.s3obj_data[count.index].key
    source = local.s3obj_data[count.index].src

    # Allow templating to execute before the files are uploaded to s3 bucket 
    depends_on = [
        local_file.bootstrap_s3_obj_default_tmpl
    ]
}
resource "local_file" "bootstrap_s3_obj_default_tmpl" {
    for_each    = { for obj in local.s3obj_data : obj.src => obj.template if obj.template != null }
    content     = templatefile("${each.key}.tmpl", each.value)
    filename    = each.key
}
