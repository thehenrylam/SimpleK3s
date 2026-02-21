# OPENTOFU : SIMPLE K3S

terraform {
    required_providers {
        aws = {
            source  = "hashicorp/aws"
            version = ">= 6.0"
        }
        assert = {
            source = "opentofu/assert"
            version = "0.14.0"
        }
    }
}

# Establish AWS Provider
provider "aws" {
    region = var.aws_region
}

locals {
    # DNS name
    dns_basename    = var.dns.basename
    dns_prefix      = coalesce(var.dns.prefix, "k3s")
    domain_name     = "${local.dns_prefix}.${local.dns_basename}"

    idp_ssm_pstore_names = {
        # IdP SSM Parameter Names
        #   What its used for: Used to enable SSO for apps
        #   Required Actions:
        #       - Go to SimpleK3s/examples/ex_idp/
        #       - Create the IdP resource (Customize the DNS name)
        #       - Use the SSM Param Output via `terraform output -json`
        #           - NOTE: Default values are already provided 
        #             (Only need to change this if you change the idp-standalone nickname)
        # idp_config's should have a JSON string the following format:
        # {
        #     issuer        = __IDP_ISSUER_URL__
        #     client_id     = __IDP_CLIENT_ID__
        #     client_secret = __IDP_CLIENT_SECRET__
        #     domain        = __IDP_HOSTED_UI_BASE_DOMAIN__
        # }
        # Use the module within ../modules/idp_cognito to create this config
        idp_config  = "/idp-standalone/idp-standalone/idp_config"
    }
}

module "vpc_cloud" {
    source                  = "../modules/vpc_cloud" 
    nickname                = var.nickname 
    node_count              = var.node_count 
    vpc_cidr_block          = var.vpc_cidr_block 
    sbn_cidr_blocks         = var.sbn_cidr_blocks 
    sbn_availability_zones  = var.sbn_availability_zones 
}

module "k3s_cluster" {
    source                  = "../../k3s_cluster" 
    nickname                = var.nickname 
    aws_region              = var.aws_region
    node_count              = var.node_count 
    admin_ip_list           = var.admin_ip_list 
    vpc_id                  = module.vpc_cloud.vpc_id 
    subnet_ids              = module.vpc_cloud.subnet_public_ids 

    applications = {
        argocd = { # Deployer: ArgoCD   
            idp_ssm_pstore_names    = local.idp_ssm_pstore_names
            domain_name             = local.domain_name
        }
        monitoring = { # Monitoring: Prometheus & Grafana
            idp_ssm_pstore_names    = local.idp_ssm_pstore_names
            domain_name             = local.domain_name
        }
    }
}

# Publish the cluster via Route 53
# Retrieve information from the route53 zone
data "aws_route53_zone" "r53" {
    name            = local.dns_basename
    private_zone    = false
}
# Create CNAME record
resource "aws_route53_record" "r53_record_k3s" {
    zone_id = data.aws_route53_zone.r53.zone_id
    name    = "${local.domain_name}"
    type    = "CNAME"
    ttl     = 300
    records = [module.k3s_cluster.k3s_cluster_load_balancer.dns_name] 
}
