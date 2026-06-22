locals {
  performance_profile = {
    standard = {
      longhorn_manager = {
        resources = {
          req = local.resource_presets.sml
          lmt = local.resource_presets.lrg
        }
      }
      longhorn_ui = {
        resources = {
          req = local.resource_presets.tny
          lmt = local.resource_presets.sml
        }
      }
      longhorn_driver = {
        resources = {
          req = local.resource_presets.tny
          lmt = local.resource_presets.sml
        }
      }
    }
  }
}
