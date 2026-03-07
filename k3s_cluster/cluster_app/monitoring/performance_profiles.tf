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
        }
    }
}
