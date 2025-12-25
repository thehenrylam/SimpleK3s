terraform {
    required_providers {
        aws = {
            source  = "hashicorp/aws"
            version = ">= 6.0"
        }
        # Used by tls_private_key
        tls = {
            source  = "hashicorp/tls"
            version = ">= 4.0"
        }
        # Used by random_string
        random = {
            source  = "hashicorp/random"
            version = ">= 3.0"
        }
        # Used by local_file
        local = {
            source  = "hashicorp/local"
            version = ">= 2.0"
        }
        # Used by assert
        assert = {
            source = "opentofu/assert"
            version = "0.14.0"
        }
    }
}

##############################
# Subnet lookup (for CIDRs)  #
##############################
data "aws_subnet" "selected" {
  count = length(var.subnet_ids)
  id    = var.subnet_ids[count.index]
}

data "aws_subnet" "controller" {
  id = coalesce(var.controller_subnet_id, var.subnet_ids[0])
}

locals {
    module              = "k3s"
    module_name         = "${local.module}-${var.nickname}"

    irole_name          = "irole-${local.module_name}_ssm-for-ec2"
    iprofile_name       = "iprofile-${local.module_name}_ssm-for-ec2"

    ec2_name            = "ec2-${local.module_name}"
    sg_ec2_name         = "sg-${local.module_name}_for-ec2"

    elb_name            = "elb-${local.module_name}"
    sg_elb_name         = "sg-${local.module_name}_for-elb"
    lport_name          = "lport-${local.module_name}"

    tgroup_name         = "tgroup-${local.module_name}"
    tgroup_name_6443    = "${local.tgroup_name}-6443"
    tgroup_name_80      = "${local.tgroup_name}-80"
    tgroup_name_443     = "${local.tgroup_name}-443"

    keypair_name        = "kp-${local.module_name}-node"

    # Controller node networking (node 0)
    # If the controller_subnet_id is not set, default to the FIRST subnet in subnet_ids
    controller_subnet_id    = coalesce(var.controller_subnet_id, var.subnet_ids[0])
    controller_subnet_cidr  = data.aws_subnet.controller.cidr_block
    # If the controller_private_ip is not set, compute it via cidrhost()
    controller_private_ip   = coalesce(var.controller_private_ip, cidrhost(local.controller_subnet_cidr, var.controller_private_ip_hostnum))
    controller_host         = local.controller_private_ip
}
