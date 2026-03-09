locals {
    #########################################
    #   Computed Values (Controller Node)   #
    #########################################
    # Controller node networking (node 0)
    # If the controller_subnet_id is not set, default to the FIRST subnet in subnet_ids
    controller_subnet_id            = var.controlplane.subnet_ids[0]
    controller_subnet_cidr          = data.aws_subnet.controller.cidr_block
    controller_private_ip_hostnum   = 100 # Default value to set the host number for the controller ip (XXX.XXX.XXX.100, where XXX.XXX.XXX.--- is the controller's subnet CIDR)
    # If the controller_private_ip is not set, compute it via cidrhost()
    controller_private_ip           = coalesce(var.controlplane.controller_private_ip_override, cidrhost(local.controller_subnet_cidr, local.controller_private_ip_hostnum))

    default_controlplane   = {
        node_count                   = 3
        ec2_ami_id              = "ami-01b1eba85c1cd6a3d"
        ec2_instance_type       = "t4g.medium"
        ec2_swapfile_size       = "1G"
        ebs_volume_size         = 12
        ebs_volume_type         = "gp3"
    }

    # default_agent_plane     = {
    #     count                   = 3
    #     ec2_ami_id              = "ami-01b1eba85c1cd6a3d"
    #     ec2_instance_type       = "t4g.medium"
    #     ec2_swapfile_size       = "1G"
    #     ebs_volume_size         = 12
    #     ebs_volume_type         = "gp3"
    # }

    controlplane   = {
        # General
        node_count          = coalesce(try(var.controlplane.node_count, null), local.default_controlplane.node_count)

        # EC2
        ec2_ami_id          = coalesce(try(var.controlplane.ec2_ami_id, null), local.default_controlplane.ec2_ami_id)
        ec2_instance_type   = coalesce(try(var.controlplane.ec2_instance_type, null), local.default_controlplane.ec2_instance_type)
        ec2_swapfile_size   = coalesce(try(var.controlplane.ec2_swapfile_size, null), local.default_controlplane.ec2_swapfile_size)

        # EBS
        ebs_volume_size     = coalesce(try(var.controlplane.ec2_volume_size, null), local.default_controlplane.ebs_volume_size)
        ebs_volume_type     = coalesce(try(var.controlplane.ec2_volume_type, null), local.default_controlplane.ebs_volume_type)

        # Networking
        subnet_ids          = var.controlplane.subnet_ids
        controller_private_ip_override = local.controller_private_ip
    }

    # agent_plane     = {
    #     # ...
    # }
}

#################################################
#           Subnet lookup (for CIDRs)           #
#################################################
data "aws_subnet" "selected" {
    count = length(var.controlplane.subnet_ids)
    id    = var.controlplane.subnet_ids[count.index]
}
data "aws_subnet" "controller" {
    id = local.controller_subnet_id
}

#######################################
#    EC2 instances for K3S Cluster    #
#######################################
# Set up random strings for the purposes of appending them to node names
resource "random_string" "controlplane_node_suffix" {
  count = local.controlplane.node_count
  length  = 5 
  special = false 
  upper   = false 
  numeric  = true
}
# Initialize EC2 instances for the K3s cluster
resource "aws_instance" "controlplane_ec2_node" {
    count                       = local.controlplane.node_count
    ami                         = local.controlplane.ec2_ami_id
    instance_type               = local.controlplane.ec2_instance_type
    # Distribute nodes across the provided subnets:
    # The first node (controller) goes into controller_subnet_id
    # The rest are round-robin'd across the other subnets
    subnet_id                   = local.controlplane.subnet_ids[count.index % length(local.controlplane.subnet_ids)]
    key_name                    = aws_key_pair.tls_key.key_name 
    iam_instance_profile        = aws_iam_instance_profile.iprofile_ec2.name
    security_groups             = [aws_security_group.sg_instances.id]  
    associate_public_ip_address = true
    # The first node will have the controller private IP, the rest get dynamic IPs
    private_ip = count.index == 0 ? local.controlplane.controller_private_ip_override : null

    user_data = templatefile("${path.module}/cloudinit.sh.tftpl", {
        count_index             = count.index,
        cluster_type            = "controlplane",
        bootstrap_bucket        = aws_s3_bucket.bootstrap.bucket,
        bootstrap_dir           = local.bstrap_dir,
        # Assume the first object of local.s3keys_default_bootstrap is the installation script
        s3key_install_script    = local.s3keys_default_bootstrap[0],
    })

    root_block_device {
        volume_size = local.controlplane.ebs_volume_size
        volume_type = local.controlplane.ebs_volume_type

        tags = {
            Name        = "${local.ebs_name}_controlplane-root-${random_string.controlplane_node_suffix[count.index].result}"
            Nickname    = "${var.nickname}"
        }
    }

    tags = {
        Name        = "${local.ec2_name}_controlplane-${random_string.controlplane_node_suffix[count.index].result}"
        Nickname    = "${var.nickname}"
    }
}
