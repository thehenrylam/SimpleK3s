locals {
    performance_profile = {
        # standard performance profiles
        standard = {
            controller = {
                resources = {
                    req = local.resource_presets.med
                    lmt = local.resource_presets.xxl
                }
            }
            repoServer = {
                resources = {
                    req = local.resource_presets.med
                    lmt = local.resource_presets.xxl
                }
            }
            applicationSet = {
                resources = {
                    req = local.resource_presets.sml
                    lmt = local.resource_presets.lrg
                }
            }
            dex = {
                resources = {
                    req = local.resource_presets.tny
                    lmt = local.resource_presets.med
                }
            }
            redis = {
                resources = {
                    req = local.resource_presets.tny
                    lmt = local.resource_presets.lrg
                }
            }
            notifications = {
                resources = {
                    req = local.resource_presets.tny
                    lmt = local.resource_presets.lrg
                }
            }
            server = {
                resources = {
                    req = local.resource_presets.sml
                    lmt = local.resource_presets.xl
                }
            }
        }
    }
}
