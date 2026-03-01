locals {
    iam_config = {
        role_name   = var.iam_config.role_name
        partition   = coalesce(try(var.iam_config.partition, null), "*")
        region      = coalesce(try(var.iam_config.region, null), "*")
        account_id  = coalesce(try(var.iam_config.account_id, null), "*")
    }

    ipolicy_pstore_name     = "ipolicy-${var.module_name}-paramstore"
    ipolicy_pstore_arn_root = "arn:${local.iam_config.partition}:ssm:${local.iam_config.region}:${local.iam_config.account_id}:parameter"

    # Reformat the list of pstore_data to be indexed by name instead
    pstore_data_by_name = { for p in var.pstore_data : p.name => p }

    tags_default = {
        Nickname    = var.nickname
        Module      = var.module_name
    }
}

#################################
#   SSM Parameter : Prechecks   #
#################################
data "aws_ssm_parameter" "pstores" {
    for_each        = local.pstore_data_by_name
    name            = each.key
    with_decryption = each.value.encrypted
}

locals {
    # Centralize all of our pstore data to make it easier to set up other components easier
    processed_pstores = { for name, o in data.aws_ssm_parameter.pstores : name => {
        alias       = local.pstore_data_by_name[name].alias
        name        = o.name
        encrypted   = local.pstore_data_by_name[name].encrypted
        region      = o.region
        ipolicy_arn = "${local.ipolicy_pstore_arn_root}/${o.name}"
    } }
}

#################################################
#    IAM Policy : K3S Token Parameter Storage   #
#################################################
# Attach permission policy (least-privilege policy for IdP issuer_url,client_id,secret_token)
resource "aws_iam_role_policy_attachment" "pstore" {
    role       = local.iam_config.role_name 
    policy_arn = aws_iam_policy.pstore.arn
}

# Establish IAM Policy using document
resource "aws_iam_policy" "pstore" {
    name    = local.ipolicy_pstore_name
    policy  = data.aws_iam_policy_document.pstore.json

    tags    = merge(var.tags, merge(local.tags_default), {
        Name = local.ipolicy_pstore_name
    })
}

# Setup policy document
data "aws_iam_policy_document" "pstore" {
    statement {
        actions = [
            "ssm:GetParameter",
            "kms:Decrypt"
        ]
        resources = [ for i, o in local.processed_pstores : o.ipolicy_arn ]
    }
}
