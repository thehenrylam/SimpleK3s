locals {
    tags_default = {
        Nickname    = var.nickname
        Module      = var.module_name
    }
}

###################################
#    S3 Files : Bootstrapping     #
###################################
# plan-time checks
resource "terraform_data" "s3obj_check" {
    # Make sure that all of the files set within var.s3obj_data is present and templatable (if applicable)
    # each.key      : Filepaths to be transferred over to the s3 bucket (if templated, assume to have ".tmpl" extension)
    # each.value    : Template object to use for templating (determines what types of checks we will use)
    for_each = { for i, o in var.s3obj_data : o.src => o.template }

    input = {
        # IF template IS null       : Check if file exists
        # IF template ISN'T null    : Check if file can be templated
        sha_check = (
            each.value == null ? filesha256( each.key ) : sha256( templatefile( "${each.key}.tmpl", jsondecode(each.value) ) )
        )
    }
}

# Upload the data files to S3
resource "aws_s3_object" "s3obj" {
    count  = length(var.s3obj_data)
    bucket = var.s3_bucket_id
    key    = var.s3obj_data[count.index].key
    source = var.s3obj_data[count.index].src

    tags    = merge(var.tags, merge(local.tags_default), {
        Name = var.s3obj_data[count.index].key
    })

    # Allow templating to execute before the files are uploaded to s3 bucket 
    depends_on = [
        local_file.s3obj_tmpl
    ]
}

# Template the data files (if applicable)
resource "local_file" "s3obj_tmpl" {
    for_each    = { for obj in var.s3obj_data : obj.src => obj.template if obj.template != null }
    content     = templatefile("${each.key}.tmpl", jsondecode(each.value))
    filename    = each.key
}
