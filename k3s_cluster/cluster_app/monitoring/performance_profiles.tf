locals {
  performance_profile = {
    # standard performance profiles
    standard = {
      grafana = {
        resources = {
          req = {
            cpu = local.resource_presets.sml.cpu
            mem = local.resource_presets.med.mem
          }
          lmt = local.resource_presets.xxl
        }
      }
      prometheus = {
        resources = {
          req = {
            cpu = local.resource_presets.lrg.cpu
            mem = local.resource_presets.ult.mem
          }
          lmt = {
            cpu = local.resource_presets.ult.cpu
            mem = local.resource_presets.xu.mem
          }
        }
      }
      alertmanager = {
        resources = {
          req = local.resource_presets.sml
          lmt = local.resource_presets.lrg
        }
      }
      prometheusOperator = {
        resources = {
          req = local.resource_presets.med
          lmt = local.resource_presets.xxl
        }
      }
      kube-state-metrics = {
        resources = {
          req = local.resource_presets.sml
          lmt = local.resource_presets.lrg
        }
      }
      prometheus-node-exporter = {
        resources = {
          req = local.resource_presets.tny
          lmt = local.resource_presets.lrg
        }
      }
      # Thanos sidecar: injected into the Prometheus pod by the operator. Light —
      # it just watches the TSDB dir and uploads 2h blocks to S3 — but it still
      # needs requests/limits to satisfy the require-requests-limits policy.
      thanos_sidecar = {
        resources = {
          req = local.resource_presets.sml
          lmt = {
            cpu = local.resource_presets.lrg.cpu
            mem = local.resource_presets.lrg.mem
          }
        }
      }
      # Thanos Querier: stateless fan-out over StoreAPIs; light unless a query
      # touches a wide time range. Memory can spike on big queries.
      thanos_query = {
        resources = {
          req = local.resource_presets.sml
          lmt = local.resource_presets.xxl
        }
      }
      # Thanos Store Gateway: holds block index headers in memory, so it leans
      # memory-heavy relative to CPU.
      thanos_store = {
        resources = {
          req = {
            cpu = local.resource_presets.med.cpu
            mem = local.resource_presets.med.mem
          }
          lmt = {
            cpu = local.resource_presets.xxl.cpu
            mem = local.resource_presets.ult.mem
          }
        }
      }
      # Thanos Compactor: singleton; bursts CPU and memory during compaction /
      # downsampling passes, idle otherwise.
      thanos_compactor = {
        resources = {
          req = {
            cpu = local.resource_presets.med.cpu
            mem = local.resource_presets.med.mem
          }
          lmt = {
            cpu = local.resource_presets.ult.cpu
            mem = local.resource_presets.xu.mem
          }
        }
      }
    }
  }
}
