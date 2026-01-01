#######################################
#    EC2 instances for K3S Cluster    #
#######################################
# Set up random strings for the purposes of appending them to node names
resource "random_string" "node_suffix" {
  count = var.node_count
  length  = 5 
  special = false 
  upper   = false 
  numeric  = true
}
# Initialize EC2 instances for the K3s cluster
resource "aws_instance" "ec2_node" {
    count                         = var.node_count
    ami                           = var.ec2_ami_id
    instance_type                 = var.ec2_instance_type
    # Distribute nodes across the provided subnets:
    # The first node (controller) goes into controller_subnet_id
    # The rest are round-robin'd across the other subnets
    subnet_id                     = count.index == 0 ? local.controller_subnet_id : var.subnet_ids[count.index % length(var.subnet_ids)]
    key_name                      = aws_key_pair.tls_key.key_name 
    iam_instance_profile          = aws_iam_instance_profile.iprofile_ec2.name
    security_groups               = [aws_security_group.sg_instances.id]  
    associate_public_ip_address   = true
    # The first node will have the controller private IP, the rest get dynamic IPs
    private_ip = count.index == 0 ? local.controller_private_ip : null

    user_data = templatefile("${path.module}/cloudinit.sh.tftpl", {
        count_index             = count.index,
        bootstrap_bucket        = aws_s3_bucket.bootstrap.bucket,
        bootstrap_dir           = local.bstrap_dir,
        s3key_simplek3s_env     = aws_s3_object.simplek3s_env.key,
        s3key_k3s_install       = aws_s3_object.k3s_install.key,
        s3key_traefik_cfg_tmpl  = aws_s3_object.traefik_cfg_tmpl.key,
    })

    root_block_device {
        volume_size = var.ec2_ebs_volume_size
        volume_type = var.ec2_ebs_volume_type

        tags = {
            Name        = "${local.ebs_name}-root-${random_string.node_suffix[count.index].result}"
            Nickname    = "${var.nickname}"
        }
    }

    tags = {
        Name        = "${local.ec2_name}-${random_string.node_suffix[count.index].result}"
        Nickname    = "${var.nickname}"
    }
}
