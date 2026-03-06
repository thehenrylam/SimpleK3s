# ##############################################
# #    Bootstrapping (Setup After Creation)    #
# ##############################################
# # SSM Parameter: Convert parameter store data into ssm params
# # Dynamic - Value can change without having Terraform report it
# resource "aws_ssm_parameter" "ssm_params_dynamic" {
#     count       = length(local.pstore_data)

#     description = local.pstore_data[ count.index ].desc
#     type        = local.pstore_data[ count.index ].type    
#     name        = local.pstore_data[ count.index ].key
#     value       = local.pstore_data[ count.index ].val

#     tags = {
#         Name        = local.pstore_data[ count.index ].name
#         Nickname    = var.nickname
#     }

#     lifecycle {
#         ignore_changes = [
#             value # This is expected to change, so we ignore it
#         ]
#     }
# }
