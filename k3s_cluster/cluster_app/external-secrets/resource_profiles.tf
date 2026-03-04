locals {
    resource_profile = {
        # standard resource profiles
        standard = {
            generic = {
                replicas = {
                    target  = 2
                    minimum = 1
                }
                req = local.resource_presets.sml
                lmt = local.resource_presets.med
            }
            webhook = {
                replicas = {
                    target  = 2
                    minimum = 1
                }
                req = local.resource_presets.sml
                lmt = local.resource_presets.med
            }
            certController = {
                replicas = {
                    target  = 2
                    minimum = 1
                }
                req = local.resource_presets.tny
                lmt = local.resource_presets.sml
            }
        }
    }
}
