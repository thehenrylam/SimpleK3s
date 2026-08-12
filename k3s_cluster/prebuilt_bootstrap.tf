# ####################################
# #  LOCALS : S3 Bootstrap : Files   #
# ####################################
locals {
  # Enable this when there are meaningful configs to adjust bootstrap behavior
  # bootstrap = merge(local.bootstrap_default, var.bootstrap)

  s3_config_bootstrap = {
    id      = aws_s3_bucket.bootstrap.id
    keyroot = local.s3_bstrap_key_root_default
  }
  iam_config_bootstrap = {
    role_name = aws_iam_role.irole_ec2.name
    partition = data.aws_partition.current.partition
  }
}

# Output data (Typically used for modules outside the file)
locals {
  # The cloud-init entry point, taken BY NAME from the bootstrap module.
  #
  # This replaces a s3keys_default_bootstrap[0] lookup, which assumed the install
  # script was the first entry of the module's key list. That list is now sorted by
  # key rather than ordered by declaration, so its first element is no longer the
  # install script — positional access here would silently boot every node with the
  # wrong file. The list local itself is gone; nothing else consumed it.
  s3key_install_script = module.cluster_app_bootstrap.s3key_install_script
}

module "cluster_app_bootstrap" {
  source = "./cluster_app/bootstrap"
  # General settings
  nickname = var.nickname
  settings = {
    version         = var.k3s_version
    pstore_key_root = local.pstore_key_root
    env_vars = jsonencode({
      bootstrap_dir      = local.bstrap_dir
      nickname           = var.nickname
      aws_region         = var.aws_region
      controller_host    = local.controller_private_ip          # local.controller_host
      swapfile_alloc_amt = local.controlplane.ec2_swapfile_size # var.ec2_swapfile_size
      pstore_key_root    = local.pstore_key_root
      s3_bucket_name     = local.s3_bstrap_name
    })
  }
  # S3 settings
  s3_config = local.s3_config_bootstrap
  # IAM settings 
  iam_config = local.iam_config_bootstrap
}
