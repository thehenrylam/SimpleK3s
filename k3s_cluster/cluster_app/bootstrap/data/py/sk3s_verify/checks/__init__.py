"""The complete set of checks.

build_registry is the index: what runs, in what order, and at what depth is
readable here rather than inferred from decorator execution during import.
"""

from ..registry import QUICK, STANDARD, Check
from . import apps, core, subsystems


def build_registry():
    return [
        # Cluster-level. QUICK is the liveness floor: if these fail, nothing
        # below them can be trusted.
        Check("k3s_api", QUICK, core.k3s_api),
        Check("nodes", QUICK, core.nodes_ready),
        Check("kube_system", QUICK, core.kube_system),
        # Subsystems.
        Check("traefik", STANDARD, subsystems.traefik),
        Check("kyverno", STANDARD, subsystems.kyverno),
        Check("longhorn", STANDARD, subsystems.longhorn),
        Check("external_secrets", STANDARD, subsystems.external_secrets),
        Check("karpenter", STANDARD, subsystems.karpenter),
        Check("descheduler", STANDARD, subsystems.descheduler),
        Check("tailscale", STANDARD, subsystems.tailscale),
        # Applications.
        Check("argocd", STANDARD, apps.argocd),
        Check("monitoring", STANDARD, apps.monitoring),
        # Cross-cutting. Last, because a restart caused by anything above is
        # more useful read after the thing that caused it.
        Check("pod_stability", STANDARD, core.pod_stability),
    ]
