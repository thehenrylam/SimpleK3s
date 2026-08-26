locals {
  resource_profile = {
    # standard resource profiles
    standard = {
      karpenter = {
        # Karpenter publishes no sizing guidance: its Helm chart ships
        # `resources: {}` on purpose ("a conscious choice for the user"), and the
        # EKS best-practices guide is silent on the controller pod. These values
        # are therefore ours, and are set from measurement rather than a default.
        #
        # Measured on a live 5-node cluster: 281Mi peak working set, across a full
        # provisioning + consolidation cycle. 384Mi leaves ~37% headroom.
        #
        # The dominant term is Karpenter's instance-type catalogue — it caches
        # every type in the region (1,346 distinct instance_type label values
        # observed) regardless of what the NodePool actually allows. That cost is
        # essentially constant, so this does NOT scale with cluster size and the
        # headroom does not need to.
        #
        # Was 512Mi. Trimmed because the reservation, not the usage, was what
        # pushed Prometheus (1152Mi) off the agent node and made Karpenter
        # provision a node to hold it — a ~$24/mo node standing in for 128Mi of
        # memory nothing was using.
        req = {
          cpu = "250m"
          mem = "384Mi"
        }
        # Limit deliberately left above the request. AWS recommends requests==limits
        # for non-CPU resources under consolidation (bursting pods can OOM a
        # bin-packed node), but Karpenter is what recovers the cluster from
        # scheduling failures — capping it at its own measured peak trades a small
        # overcommit risk for a much worse failure mode.
        lmt = {
          cpu = "1000m"
          mem = "1Gi"
        }
      }
    }
  }
}
