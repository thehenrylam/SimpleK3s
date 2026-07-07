# OpenTofu / Terraform : SIMPLE K3S

terraform {
  required_version = "~> 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Establish AWS Provider
provider "aws" {
  region = var.aws_region
}

locals {
  # DNS name
  dns_basename = var.dns.basename
  dns_prefix   = coalesce(var.dns.prefix, "k3s")
  domain_name  = "${local.dns_prefix}.${local.dns_basename}"

  # IdP SSM Parameter Name
  #   What its used for: Used to enable SSO for apps
  #   Required Actions:
  #       - Go to SimpleK3s/examples/ex_idp/
  #       - Create the IdP resource (Customize the DNS name)
  #       - Use the SSM Param Output via `terraform output -json`
  #           - NOTE: Default values are already provided 
  #             (Only need to change this if you change the idp-standalone nickname)
  # idp_config's should have a JSON string with the following format:
  # {
  #     issuer        = __IDP_ISSUER_URL__
  #     client_id     = __IDP_CLIENT_ID__
  #     client_secret = __IDP_CLIENT_SECRET__
  #     domain        = __IDP_HOSTED_UI_BASE_DOMAIN__
  # }
  # Use the module within ../modules/idp_cognito to create this config
  pstore_idp_config = "/idp-standalone/idp-standalone/idp_config"

  # PVC SSM Parameter Name
  #   What its used for: Enables SimpleK3s to leverage PVCs for its apps (This is not managed by SimpleK3s itself to properly retain data even after it undergoes a terraform/tofu destroy)
  #   Required Actions:
  #       - Go to SimpleK3s/examples/ex_pvc
  #       - Create the PVC resource (Customize the settings, be sure that the EBS sizes are greater than the requested memory by at least 0.5Gi)
  #       - Use the SSM Param Output via `terraform output -json`
  #           - NOTE: Default values are already provided 
  #             (Only need to change this if you change the pvc-standalone nickname)
  # pvc_pool_platform's should have a JSON string with the following format (s.t. n == number of AZs defined in the PVC allocation):
  # [
  #     "vol-id_of_ebs_volume_for_az_0",
  #     "vol-id_of_ebs_volume_for_az_1",
  #     "vol-id_of_ebs_volume_for_az_2",
  #     ...
  #     "vol-id_of_ebs_volume_for_az_n"
  # ] 
  pvc_pool_platform = "/pvc-standalone/pvc-standalone/pvc_pool_platform"

  # TailScale SSM Parameter Name
  #   What its used for: Enables SimpleK3s to talk to Tailscale to properly set up Tailscale as an entrypoint into your apps
  #   Required Actions:
  #       - Go to SimpleK3s/examples/ex_pstore_tailscale
  #       - Make sure that the following variables are set up in terraform.tfvars file:
  #           - tailscale_oauth_client_id
  #           - tailscale_oauth_client_secret
  #       - Create the Tailscale PStore resource
  #       - Use the SSM Param Output via `terraform output -json`
  #           - NOTE: Default values are already provided 
  #             (Only need to change this if you change the tailscale-standalone nickname)
  # tailscale_oauth's should have a JSON string with the following format:
  # {
  #     client_id     = __TAILSCALE_CLIENT_ID__
  #     client_secret = __TAILSCALE_CLIENT_SECRET__
  # }
  pstore_tailscale_oauth = "/tailscale-standalone/tailscale-standalone/oauth_config"
  # tailscale_oauth's should have a JSON string with the following format:
  # {
  #     dns_name  = __TAILSCALE_MAGIC_DNS_NAME__
  # }
  pstore_tailscale_magic_dns_name = "/tailscale-standalone/tailscale-standalone/magic_dns_name"
  magic_dns_name                  = jsondecode(data.aws_ssm_parameter.pstore_tailscale_magic_dns_name.value).dns_name
}

# Determine the tailscale Magic DNS Name. Since this isn't sensitive information, we can freely retrieve this data within the TF module
# The reason why we don't set Magic DNS name here is because we want to keep tailscale specific settings separate from the general settings
data "aws_ssm_parameter" "pstore_tailscale_magic_dns_name" {
  name = local.pstore_tailscale_magic_dns_name
}

module "vpc_cloud" {
  source                 = "../modules/vpc_cloud"
  nickname               = var.nickname
  node_count             = var.node_count
  vpc_cidr_block         = var.vpc_cidr_block
  sbn_cidr_blocks        = var.sbn_cidr_blocks
  sbn_availability_zones = var.sbn_availability_zones
}

module "k3s_cluster" {
  source        = "../../k3s_cluster"
  nickname      = var.nickname
  aws_region    = var.aws_region
  admin_ip_list = var.admin_ip_list
  vpc_id        = module.vpc_cloud.vpc_id
  subnet_ids    = module.vpc_cloud.subnet_public_ids

  controlplane = {
    node_count = 3
  }

  agentplane = {
    node_count = 0
  }

  subsystems = {
    # If activated, it exposes admin apps via tailnet instead of public LB (more secure)
    # Remember: If you enable this, please set the apps' configs to `exposure = "internal"`
    tailscale = {
      pstore_oauth   = local.pstore_tailscale_oauth
      tags           = ["tag:k8s"]
      magic_dns_name = local.magic_dns_name
    }

    karpenter = {
      version                = "1.9.0"
      capacity_type          = "on-demand"
      arch                   = "arm64"
      instance_categories    = ["t"] # ["m", "c", "r"]
      instance_generation_gt = 3
      cpu_limit              = "32"
      memory_limit           = "128Gi"
      consolidate_after      = "5m"
    }

    # Persistent storage — deploy examples/ex_pvc first to create the EBS volumes.
    # ebs_volumes_pstore_name must match the SSM parameter created by ex_pvc.
    longhorn = {
      pools = [
        {
          name                    = "platform"
          default                 = true
          ebs_volumes_pstore_name = local.pvc_pool_platform
          node_target             = "controlplane"
          reclaim_policy          = "Retain"
          data_locality           = "disabled"
          backup_s3_prefix        = "longhorn-backups/platform/"
        }
      ]
    }
  }

  applications = {
    argocd = { # Deployer: ArgoCD
      pstore_idp_config = local.pstore_idp_config
      domain_name       = local.domain_name
      exposure          = "internal" # "external" # public LB via Traefik (use "internal" for tailnet-only)
    }
    monitoring = { # Monitoring: Prometheus & Grafana (+ Thanos long-term storage)
      pstore_idp_config = local.pstore_idp_config
      domain_name       = local.domain_name
      exposure          = "internal" # "external" # public LB via Traefik (use "internal" for tailnet-only)
      storage = {
        pool_name = "platform"
        components = {
          grafana      = { pvc_size = 0.75 }
          prometheus   = { pvc_size = 8 }
          alertmanager = { pvc_size = 0.75 }
        }
      }
    }
  }
}

# Publish the cluster via Route 53
# Retrieve information from the route53 zone
data "aws_route53_zone" "r53" {
  name         = local.dns_basename
  private_zone = false
}
# Create CNAME record
resource "aws_route53_record" "r53_record_k3s" {
  zone_id = data.aws_route53_zone.r53.zone_id
  name    = local.domain_name
  type    = "CNAME"
  ttl     = 300
  records = [module.k3s_cluster.k3s_cluster_load_balancer.dns_name]
}
