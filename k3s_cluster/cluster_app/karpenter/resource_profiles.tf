locals {
    resource_profile = {
        # standard resource profiles
        standard = {
            karpenter = {
                req = {
                    cpu = "250m"
                    mem = "512Mi"
                }
                lmt = {
                    cpu = "1000m"
                    mem = "1Gi"
                }
            }
        }
    }
}
