locals {
    resource_profile = {
        # standard resource profiles
        standard = {
            traefik = {
                replicas = {
                    target  = 2
                    minimum = 1
                }
                req = local.resource_presets.sml
                lmt = local.resource_presets.lrg
            }
        }
    }
}
