locals {
    module_name = "k3s_app_argocd"

    iam_config = {
        partition   = coalesce(var.iam_config.partition, "*")
        region      = coalesce(var.iam_config.region, "*")
        account_id  = coalesce(var.iam_config.account_id, "*")
    }

    ipolicy_idp_pstore_name     = "ipolicy-${local.module_name}_idp-paramstore"
    ipolicy_idp_pstore_arn_root = "arn:${local.iam_config.partition}:ssm:${local.iam_config.region}:${local.iam_config.account_id}:parameter"

    idp_ssm_pstore_names    = var.settings.idp_ssm_pstore_names
    domain_name             = var.settings.domain_name

    s3_bucket_id    = var.s3_bucket_id 
    s3obj_data      = var.s3obj_data 
}

#################################
#   SSM Parameter : Prechecks   #
#################################
data "aws_ssm_parameter" "issuer" {
    name            = local.idp_ssm_pstore_names.issuer
    with_decryption = true
}

data "aws_ssm_parameter" "client" {
    name            = local.idp_ssm_pstore_names.client
    with_decryption = true
}

data "aws_ssm_parameter" "secret" {
    name            = local.idp_ssm_pstore_names.secret
    with_decryption = true
}


###################################
#    S3 Files : Bootstrapping     #
###################################
# plan-time checks
resource "terraform_data" "s3obj_check" {
    # Make sure that all of the files set within local.s3obj_data is present and templatable (if applicable)
    # each.key      : Filepaths to be transferred over to the s3 bucket (if templated, assume to have ".tmpl" extension)
    # each.value    : Template object to use for templating (determines what types of checks we will use)
    for_each = { for i, o in local.s3obj_data : o.src => o.template }

    input = {
        # IF template IS null       : Check if file exists
        # IF template ISN'T null    : Check if file can be templated
        sha_check = (
            each.value == null ? filesha256( each.key ) : sha256( templatefile( "${each.key}.tmpl", jsondecode(each.value) ) )
        )
    }
}

# Template and upload data files to S3 (default)
resource "aws_s3_object" "s3obj" {
    count  = length(local.s3obj_data)
    bucket = local.s3_bucket_id
    key    = local.s3obj_data[count.index].key
    source = local.s3obj_data[count.index].src

    # Allow templating to execute before the files are uploaded to s3 bucket 
    depends_on = [
        local_file.s3obj_tmpl
    ]
}
resource "local_file" "s3obj_tmpl" {
    for_each    = { for obj in local.s3obj_data : obj.src => obj.template if obj.template != null }
    content     = templatefile("${each.key}.tmpl", jsondecode(each.value))
    filename    = each.key
}

#################################################
#    IAM Policy : K3S Token Parameter Storage   #
#################################################
# Attach permission policy (least-privilege policy for IdP issuer_url,client_id,secret_token)
resource "aws_iam_role_policy_attachment" "idp_pstore" {
    role       = var.iam_role_name 
    policy_arn = aws_iam_policy.idp_pstore.arn
}

# Establish IAM Policy using document
resource "aws_iam_policy" "idp_pstore" {
    name   = local.ipolicy_idp_pstore_name
    policy = data.aws_iam_policy_document.idp_pstore.json
}

# Setup policy document
data "aws_iam_policy_document" "idp_pstore" {
    statement {
        actions = [
            "ssm:GetParameter",
            "kms:Decrypt"
        ]
        resources = [
            "${local.ipolicy_idp_pstore_arn_root}/${local.idp_ssm_pstore_names.issuer}",
            "${local.ipolicy_idp_pstore_arn_root}/${local.idp_ssm_pstore_names.client}",
            "${local.ipolicy_idp_pstore_arn_root}/${local.idp_ssm_pstore_names.secret}",
        ]
    }
}

