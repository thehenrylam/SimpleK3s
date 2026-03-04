locals {
    resource_profile = {
        # standard resource profiles
        standard = {
            kyverno = {
                replicas = {
                    target  = 2
                    minimum = 1
                }
                req = local.resource_presets.med
                lmt = {
                    cpu = local.resource_presets.lrg.cpu,
                    mem = local.resource_presets.xxl.mem
                }
            }

            # ---

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
