locals {
  resource_profile = {
    # standard resource profiles
    standard = {
      karpenter = {
        # 384Mi set from measurement (281Mi peak); Karpenter ships no default.
        req = {
          cpu = "250m"
          mem = "384Mi"
        }
        # Limit deliberately above request, against AWS's requests==limits advice:
        # OOM-killing Karpenter mid-scheduling-storm is the worse failure mode.
        lmt = {
          cpu = "1000m"
          mem = "1Gi"
        }
      }
    }
  }
}
