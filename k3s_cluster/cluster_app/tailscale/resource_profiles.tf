locals {
  resource_profile = {
    # standard resource profile (the operator is light)
    standard = {
      operator = {
        req = local.resource_presets.sml
        lmt = local.resource_presets.med
      }
      proxy = {
        req = local.resource_presets.tny
        lmt = local.resource_presets.sml
      }
    }
  }
}
