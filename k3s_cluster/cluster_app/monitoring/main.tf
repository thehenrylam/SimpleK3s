terraform {
  required_version = "~> 1.11"
}

locals {
  module_name = "cluster_app_${basename(path.module)}"

  # Thanos image: the sidecar (Prometheus), Store Gateway, Querier, and Compactor
  # all run this version. See the Pinned Versions table in CLAUDE.md.
  thanos_image = "quay.io/thanos/thanos:v0.41.0"

  settings = {
    version           = coalesce(try(var.settings.version, null), "0.1.0-alpha.0")
    pstore_idp_config = var.settings.pstore_idp_config
    domain_name       = var.settings.domain_name
    exposure          = coalesce(try(var.settings.exposure, null), "internal")
    scrape_interval   = coalesce(try(var.settings.scrape_interval, null), "60s")
    # LOCAL Prometheus retention only. Long-term history lives in S3 via the
    # Thanos sidecar, so this stays short (default 6h) to keep the PVC small.
    retention = coalesce(try(var.settings.retention, null), "6h")
    storage = {
      storage_class_name    = var.storage_class_name != null ? var.storage_class_name : ""
      grafana_enabled       = var.storage_class_name != null && try(var.settings.storage.components.grafana.pvc_size, 0) > 0
      grafana_pvc_size      = try(var.settings.storage.components.grafana.pvc_size, 0)
      prometheus_enabled    = var.storage_class_name != null && try(var.settings.storage.components.prometheus.pvc_size, 0) > 0
      prometheus_pvc_size   = try(var.settings.storage.components.prometheus.pvc_size, 0)
      alertmanager_enabled  = var.storage_class_name != null && try(var.settings.storage.components.alertmanager.pvc_size, 0) > 0
      alertmanager_pvc_size = try(var.settings.storage.components.alertmanager.pvc_size, 0)
    }
  }

  # Shared tailnet host (one device fronts Traefik for all internal apps). Grafana
  # and Prometheus are reached at https://<host>/grafana and /prometheus, path-routed
  # by Traefik — mirrors external mode. magic_dns_name is null for external-only
  # clusters; guard the interpolation (the internal+null combination is rejected by
  # the plan-time exposure check).
  internal_host = "${coalesce(var.internal_host_prefix, var.nickname)}.${var.magic_dns_name == null ? "" : var.magic_dns_name}"

  # Base URL each service advertises (Grafana root_url / Prometheus externalUrl +
  # OIDC redirect). Internal must match the tailnet host so SSO callbacks resolve;
  # external uses the public domain served by Traefik.
  base_url = local.settings.exposure == "internal" ? "https://${local.internal_host}" : "https://${local.settings.domain_name}"

  # Resource presets (to put into performance profiles)
  resource_presets = module.common.resource_presets
}

# Get common values (i.e. resource_presents)
module "common" {
  source = "../utils/common_values"
}

# Set up the aws pstore
module "aws_pstore" {
  source = "../utils/aws_pstore"
  # General variables
  nickname    = var.nickname
  module_name = local.module_name
  # IAM config
  iam_config = var.iam_config
  # Parameter store data
  pstore_data = [
    {
      alias     = "ip_config"
      name      = local.settings.pstore_idp_config
      desc      = "The IDP Config - Enables SSO for the underling app"
      encrypted = true
      create    = false # Set to false: SSM ParamStore provided by an outside source
    }
  ]
}

# Set up the aws s3obj
module "aws_s3obj" {
  source = "../utils/aws_s3obj"
  # General variables
  nickname    = var.nickname
  module_name = local.module_name
  # S3 settings
  s3_bucket_id = var.s3_config.id
  s3obj_data = [
    {
      desc = "Monitoring (Prometheus & Grafana) config all-in-one (HelmChart, Secrets, ConfigMaps, etc)"
      key  = "${var.s3_config.keyroot}/manifests/monitoring.yaml"
      src  = "${path.module}/data/monitoring.yaml"
      template = jsonencode({
        version                   = local.settings.version
        domain_name               = local.settings.domain_name
        exposure                  = local.settings.exposure
        internal_host             = local.internal_host
        base_url                  = local.base_url
        pstore_idp_config         = local.settings.pstore_idp_config
        region_idp_config         = module.aws_pstore.processed_pstores[local.settings.pstore_idp_config].region
        cfg                       = merge({}, local.performance_profile["standard"])
        storage                   = local.settings.storage
        scrape_interval           = local.settings.scrape_interval
        prometheus_retention      = local.settings.retention
        prometheus_retention_size = "${floor(local.settings.storage.prometheus_pvc_size * 0.85)}GiB"
        # Thanos: ship TSDB blocks to S3 and serve long-term queries from there.
        # Always on when monitoring is enabled (the bucket is created in the root
        # module). S3 access is via the node instance profile (no keys).
        thanos_image    = local.thanos_image
        thanos_bucket   = var.thanos_bucket_name
        thanos_region   = var.aws_region
        thanos_endpoint = "s3.${var.aws_region}.amazonaws.com"
        thanos_sidecar  = local.performance_profile["standard"].thanos_sidecar
        thanos_query    = local.performance_profile["standard"].thanos_query
        thanos_store    = local.performance_profile["standard"].thanos_store
        thanos_compact  = local.performance_profile["standard"].thanos_compactor
        # Curated "Start Here" index dashboard (provisioned as a ConfigMap and set
        # as Grafana's default home). Passed as a plain string so its JSON is never
        # re-interpreted by templatefile.
        recommended_dashboard_json = file("${path.module}/data/dashboards/simplek3s-start-here.json")
      })
    },
    {
      desc     = "Monitoring (Prometheus & Grafana) installation script (to be executed by the Default Init Script)"
      key      = "${var.s3_config.keyroot}/app_monitoring.sh"
      src      = "${path.module}/data/app_monitoring.sh"
      template = null
    }
  ]
}
