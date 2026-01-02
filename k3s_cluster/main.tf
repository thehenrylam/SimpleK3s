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

###################################
#   VPC lookup (for CIDR Block)   #
###################################
data "aws_vpc" "selected" {
    id = var.vpc_id
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

########################################
# Get current AWS Partition (for IAM)  #
########################################
data "aws_partition" "current" {}
##############################################
# Get current AWS Caller Identity (for IAM)  #
##############################################
data "aws_caller_identity" "current" {}

locals {
    uninitialized       = "__UNINITIALIZED__"

    module              = "k3s"
    module_name         = "${local.module}-${var.nickname}"

    irole_name          = "irole-${local.module_name}_ssm-for-ec2"
    iprofile_name       = "iprofile-${local.module_name}_ssm-for-ec2"

    ipolicy_k3s_pstore_name = "ipolicy-${local.module_name}_k3s-paramstore"
    ipolicy_s3_bstrap_name  = "ipolicy-${local.module_name}_s3-bootstrap"

    # Bootstrapping : Infra
    # S3 bstrap (bootstrap) acts as a way to get around the 16KB cloud-init limit when initializing K3s nodes
    s3_bstrap_name          = "s3-${local.module_name}-bootstrap"
    # Bootstrapping : Data
    # Key bootstrapping values
    bstrap_dir                  = "/opt/simplek3s/"
    # Filepaths for S3
    s3_bstrap_key_root          = "bootstrap" # This is used as part of a key
    s3_bstrap_key_root_default  = "${local.s3_bstrap_key_root}/default"
    s3_bstrap_key_root_custom   = "${local.s3_bstrap_key_root}/custom"

    s3key_install_script    = "${local.s3_bstrap_key_root}/K3S_INSTALL.sh"
    s3_files_key_src_path   = [
        { # SimpleK3s Env Vars
            desc        = "SimpleK3s Env Vars",
            key         = "${local.s3_bstrap_key_root}/simplek3s.env",
            src         = local_file.simplek3s_env.filename, # This is a templated variable
            precheck    = false # Can't precheck: this is a templated file!
        },
        { # K3S Installation
            desc        = "K3S Install",
            key         = local.s3key_install_script,
            src         = "${path.module}/bootstrap/K3S_INSTALL.sh",
            precheck    = true
        },
        { # Traefik Config (Template)
            desc        = "Traefik Config (Template)",
            key         = "${local.s3_bstrap_key_root}/manifests/traefik-config.yaml.tmpl",
            src         = "${path.module}/bootstrap/manifests/traefik-config.yaml.tmpl",
            precheck    = true
        },
    ]

    k3s_install_path        = "${path.module}/bootstrap/K3S_INSTALL.sh"
    traefik_cfg_tmpl_path   = "${path.module}/bootstrap/manifests/traefik-config.yaml.tmpl"
    simplek3s_path          = "${path.module}/bootstrap/simplek3s.env"
    # SSM Parameter (for k3s_token)
    pstore_k3s_token_name   = "pstore-${local.module_name}_k3s-token" 

    ec2_name            = "ec2-${local.module_name}"
    sg_ec2_name         = "sgroup-${local.module_name}_for-ec2"

    ebs_name            = "ebs-${local.module_name}"

    elb_name            = "elb-${local.module_name}"
    sg_elb_name         = "sgroup-${local.module_name}_for-elb"
    lport_name          = "lport-${local.module_name}"

    tgroup_name         = "tgroup-${local.module_name}"
    tgroup_name_6443    = "${local.tgroup_name}-6443"
    tgroup_name_80      = "${local.tgroup_name}-80"
    tgroup_name_443     = "${local.tgroup_name}-443"

    keypair_name        = "kp-${local.module_name}-node"

    #############################
    #   Computed Values (VPC)   #
    #############################
    vpc_cidr                = data.aws_vpc.selected.cidr_block
    # IP to VPC DNS Resolver is always at VPC+2 (i.e. x.x.x.2)
    # NOTE: If you have custom DHCP options set or custom DNS servers, ensure that the DNS server IP is correctly set
    # NOTE: If you are having lots of issues with DNS resolution, try setting this to "0.0.0.0/0" to allow all outbound DNS queries
    # Link to Docs: https://tutorialsdojo.com/using-amazon-route-53-resolver/
    vpc_dns_resolver_cidr   = "${cidrhost(local.vpc_cidr, 2)}/32"

    #########################################
    #   Computed Values (Controller Node)   #
    #########################################
    # Controller node networking (node 0)
    # If the controller_subnet_id is not set, default to the FIRST subnet in subnet_ids
    controller_subnet_id    = coalesce(var.controller_subnet_id, var.subnet_ids[0])
    controller_subnet_cidr  = data.aws_subnet.controller.cidr_block
    # If the controller_private_ip is not set, compute it via cidrhost()
    controller_private_ip   = coalesce(var.controller_private_ip, cidrhost(local.controller_subnet_cidr, var.controller_private_ip_hostnum))
    controller_host         = local.controller_private_ip

    #########################################
    #   Computed Values (Caller Identity)   #
    #########################################
    account_id              = coalesce(var.account_id, data.aws_caller_identity.current.account_id)
}
