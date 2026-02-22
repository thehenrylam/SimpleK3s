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

#################################################
#          VPC lookup (for CIDR Block)          #
#################################################
data "aws_vpc" "selected" {
    id = var.vpc_id
}
#################################################
#           Subnet lookup (for CIDRs)           #
#################################################
data "aws_subnet" "selected" {
    count = length(var.subnet_ids)
    id    = var.subnet_ids[count.index]
}
data "aws_subnet" "controller" {
    id = coalesce(var.controller_subnet_id, var.subnet_ids[0])
}
#################################################
#      Get current AWS Partition (for IAM)      #
#################################################
data "aws_partition" "current" {}
#################################################
#   Get current AWS Caller Identity (for IAM)   #
#################################################
data "aws_caller_identity" "current" {}



####################################
#      LOCALS : Derive Values      #
####################################
locals {
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

####################################
#  LOCALS : S3 Bootstrap : Params  #
####################################
locals {
    # List of param-store data
    pstore_key_root = "/simplek3s/${var.nickname}"
    pstore_data = [
        {
            name    = "pstore-${local.module_name}_k3s-token"
            desc    = "The K3s token - This is set on runtime"
            type    = "SecureString"
            key     = "${local.pstore_key_root}/k3s-token"
            val   = local.uninitialized
        },
    ]
}

####################################
#  LOCALS : S3 Bootstrap : Files   #
####################################
locals {
    # Bootstrapping : Data
    # Key bootstrapping values
    bstrap_dir                  = "/opt/simplek3s/"
    # Filepaths for S3
    s3_bstrap_key_root          = "bootstrap" # This is used as part of a key
    s3_bstrap_key_root_default  = "${local.s3_bstrap_key_root}/default"
    s3_bstrap_key_root_custom   = "${local.s3_bstrap_key_root}/custom"

    # IMPORTANT: Main installation script (i.e. what we use to kick off node installation) MUST be the FIRST item
    s3obj_data   = [
        { # Default Installation (Main installation script)
            desc        = "Default Init Script",
            key         = "${local.s3_bstrap_key_root_default}/init.sh",
            src         = "${path.module}/bootstrap/default/init.sh",
            template    = null
        },
        { # SimpleK3s Env Vars
            desc        = "SimpleK3s Env Vars",
            key         = "${local.s3_bstrap_key_root_default}/simplek3s.env",
            src         = "${path.module}/bootstrap/default/simplek3s.env", 
            template    = {
                bootstrap_dir           = local.bstrap_dir
                nickname                = var.nickname
                aws_region              = var.aws_region
                controller_host         = local.controller_host
                swapfile_alloc_amt      = var.ec2_swapfile_size
                nodeport_http           = var.k3s_nodeport_traefik_http
                nodeport_https          = var.k3s_nodeport_traefik_https
                pstore_key_root         = local.pstore_key_root
                s3_bucket_name          = local.s3_bstrap_name
            }
        },
        { # Traefik Config (Template)
            desc        = "Traefik Config",
            key         = "${local.s3_bstrap_key_root_default}/manifests/traefik-config.yaml",
            src         = "${path.module}/bootstrap/default/manifests/traefik-config.yaml",
            template    = {
                nodeport_http   = var.k3s_nodeport_traefik_http 
                nodeport_https  = var.k3s_nodeport_traefik_https
            }
        },
        { # Traefik Middleware (Reroute Network Traffic from HTTP to HTTPs)
            desc        = "Traefik Middleware",
            key         = "${local.s3_bstrap_key_root_default}/manifests/traefik-middleware.yaml",
            src         = "${path.module}/bootstrap/default/manifests/traefik-middleware.yaml",
            template    = {
                ingress_http_port   = 80
            }
        },
        { # External Secrets Manifests
            desc        = "External Secrets Manifests",
            key         = "${local.s3_bstrap_key_root_default}/manifests/external-secrets.yaml",
            src         = "${path.module}/bootstrap/default/manifests/external-secrets.yaml",
            template    = null
        },
        { # Common Functions
            desc        = "Common Functions",
            key         = "${local.s3_bstrap_key_root_default}/lib/common.sh",
            src         = "${path.module}/bootstrap/default/lib/common.sh",
            template    = null
        },
        { # Common Functions (AWS)
            desc        = "Common Functions (AWS)",
            key         = "${local.s3_bstrap_key_root_default}/lib/providers/aws.sh",
            src         = "${path.module}/bootstrap/default/lib/providers/aws.sh",
            template    = null
        },
        {
            desc        = "Init Script (Install Packages)",
            key         = "${local.s3_bstrap_key_root_default}/01_install_packages.sh",
            src         = "${path.module}/bootstrap/default/01_install_packages.sh",
            template    = null
        },
        {
            desc        = "Init Script (Setup Swapfile)",
            key         = "${local.s3_bstrap_key_root_default}/02_setup_swapfile.sh",
            src         = "${path.module}/bootstrap/default/02_setup_swapfile.sh",
            template    = null
        },
        {
            desc        = "Init Script (Install K3s)",
            key         = "${local.s3_bstrap_key_root_default}/03_install_k3s.sh",
            src         = "${path.module}/bootstrap/default/03_install_k3s.sh",
            template    = null
        },
        {
            desc        = "Init Script (Apply Traefik)",
            key         = "${local.s3_bstrap_key_root_default}/04_apply_traefik.sh",
            src         = "${path.module}/bootstrap/default/04_apply_traefik.sh",
            template    = null
        },
        {
            desc        = "Init Script (Apply External Secrets)",
            key         = "${local.s3_bstrap_key_root_default}/05_apply_external-secrets.sh",
            src         = "${path.module}/bootstrap/default/05_apply_external-secrets.sh",
            template    = null
        }
    ]
}

####################################
#    LOCALS : General Variables    #
####################################
locals {
    # Static Variables (Not supposed to change!)
    uninitialized       = "__UNINITIALIZED__"

    # General Variables
    module              = "k3s"
    module_name         = "${local.module}-${var.nickname}"

    # IAM Variables
    irole_name              = "irole-${local.module_name}_ssm-for-ec2"
    iprofile_name           = "iprofile-${local.module_name}_ssm-for-ec2"
    ipolicy_k3s_pstore_name = "ipolicy-${local.module_name}_k3s-paramstore"
    ipolicy_s3_bstrap_name  = "ipolicy-${local.module_name}_s3-bootstrap"

    # EC2 (Related) Variables
    ec2_name            = "ec2-${local.module_name}"
    sg_ec2_name         = "sgroup-${local.module_name}_for-ec2"
    ebs_name            = "ebs-${local.module_name}"

    # S3 Variables
    s3_bstrap_name      = "s3-${local.module_name}-bootstrap"

    # ELB (Elastic Load Balancer) Variables
    elb_name            = "elb-${local.module_name}"
    sg_elb_name         = "sgroup-${local.module_name}_for-elb"
    lport_name          = "lport-${local.module_name}"
    # TG (Target Group) Variables
    tgroup_name         = "tgroup-${local.module_name}"
    tgroup_name_6443    = "${local.tgroup_name}-6443"
    tgroup_name_80      = "${local.tgroup_name}-80"
    tgroup_name_443     = "${local.tgroup_name}-443"

    # KeyPair Variables
    keypair_name        = "kp-${local.module_name}-node"
}

# IF ENABLED: Check and Set up all of the needed files for ArgoCD 
# Handles:
#   - S3 object upload
#   - IAM rights settings (e.g. role name of the EC2 env to allow getting secret settings from the ParameterStore)
module "k3s_app_argocd" {
    count           = var.applications.argocd != null ? 1 : 0 
    source          = "./k3s_app/argocd" 
    
    # General settings
    nickname        = var.nickname 
    settings        = var.applications.argocd 
    
    # IAM settings
    iam_role_name   = aws_iam_role.irole_ec2.name 
    iam_config      = {
        partition   = data.aws_partition.current.partition
    }

    # S3 settings
    s3_bucket_id    = aws_s3_bucket.bootstrap.id
    s3obj_data      = [
        {
            desc        = "ArgoCD config all-in-one (HelmChart, Secrets, ConfigMaps, etc)" 
            key         = "${local.s3_bstrap_key_root_default}/manifests/argocd.yaml" 
            src         = "${path.module}/bootstrap/default/manifests/argocd.yaml" 
            template    = jsonencode({
                domain_name             = var.applications.argocd.domain_name 
                idp_ssm_pstore_names    = var.applications.argocd.idp_ssm_pstore_names 
            })
        },
        {
            desc        = "ArgoCD installation script (to be executed by the Default Init Script)"
            key         = "${local.s3_bstrap_key_root_default}/optional_argocd.sh"
            src         = "${path.module}/bootstrap/default/optional_argocd.sh"
            template    = null
        }
    ]
}

# IF ENABLED: Check and Set up all of the needed files for Monitoring (Prometheus & Grafana) 
# Handles:
#   - S3 object upload
#   - IAM rights settings (e.g. role name of the EC2 env to allow getting secret settings from the ParameterStore)
module "k3s_app_monitoring" {
    count           = var.applications.monitoring != null ? 1 : 0 
    source          = "./k3s_app/monitoring" 
    
    # General settings
    nickname        = var.nickname 
    settings        = var.applications.monitoring 
    
    # IAM settings
    iam_role_name   = aws_iam_role.irole_ec2.name 
    iam_config      = {
        partition   = data.aws_partition.current.partition
    }

    # S3 settings
    s3_bucket_id    = aws_s3_bucket.bootstrap.id
    s3obj_data      = [
        {
            desc        = "Monitoring (Prometheus & Grafana) config all-in-one (HelmChart, Secrets, ConfigMaps, etc)" 
            key         = "${local.s3_bstrap_key_root_default}/manifests/monitoring.yaml" 
            src         = "${path.module}/bootstrap/default/manifests/monitoring.yaml" 
            template    = jsonencode({
                domain_name             = var.applications.monitoring.domain_name 
                idp_ssm_pstore_names    = var.applications.monitoring.idp_ssm_pstore_names 
                # var_gf_oidc_domain      = "$${GF_OIDC_DOMAIN}" # Insert a variable "${...}" into the file to be used at runtime
            })
        },
        {
            desc        = "Monitoring (Prometheus & Grafana) installation script (to be executed by the Default Init Script)"
            key         = "${local.s3_bstrap_key_root_default}/optional_monitoring.sh"
            src         = "${path.module}/bootstrap/default/optional_monitoring.sh"
            template    = null
        }
    ]
}
