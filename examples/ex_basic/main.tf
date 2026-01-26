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
}

# Publish the cluster via Route 53
# Retrieve information from the route53 zone
data "aws_route53_zone" "r53" {
    name            = var.dns_basename
    private_zone    = false
}
# Create CNAME record
resource "aws_route53_record" "r53_record_k3s" {
    zone_id = data.aws_route53_zone.r53.zone_id
    name    = "${var.dns_prefix}.${var.dns_basename}"
    type    = "CNAME"
    ttl     = 300
    records = [module.k3s_cluster.k3s_cluster_load_balancer.dns_name] 
}
