locals {
    resource_profile = {
        # standard resource profiles
        standard = {
            admissionController = {
                replicas = {
                    target  = 2
                    minimum = 1
                }
                req = {
                    cpu = local.resource_presets.med.cpu
                    mem = local.resource_presets.sml.mem
                }
                lmt = {
                    mem = local.resource_presets.xl.mem
                }
            }
            backgroundController = {
                replicas = {
                    target  = 2
                    minimum = 1
                }
                req = {
                    cpu = local.resource_presets.med.cpu
                    mem = local.resource_presets.tny.mem
                }
                lmt = {
                    mem = local.resource_presets.sml.mem
                }
            }
            cleanupController = {
                replicas = {
                    target  = 2
                    minimum = 1
                }
                req = {
                    cpu = local.resource_presets.med.cpu
                    mem = local.resource_presets.tny.mem
                }
                lmt = {
                    mem = local.resource_presets.sml.mem
                }
            }
            reportsController = {
                replicas = {
                    target  = 2
                    minimum = 1
                }
                req = {
                    cpu = local.resource_presets.med.cpu
                    mem = local.resource_presets.tny.mem
                }
                lmt = {
                    mem = local.resource_presets.sml.mem
                }
            }
        }
    }
}
