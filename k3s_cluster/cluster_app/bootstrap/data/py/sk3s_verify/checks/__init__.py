"""The complete set of checks.

build_registry is the index: what runs, in what order, and at what depth is
readable here rather than inferred from decorator execution during import.
"""

from ..registry import FULL, QUICK, STANDARD, Check
from . import apps, core, facts, subsystems, sweep


def build_registry():
    return [
        # Cluster-level. QUICK is the liveness floor: if these fail, nothing
        # below them can be trusted.
        Check("k3s_api", QUICK, core.k3s_api),
        Check("controlplane", QUICK, core.controlplane),
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
        # Cross-cutting, and last: a sweep failure caused by anything above
        # is more useful read after the named check that attributes it.
        Check("workloads", STANDARD, sweep.workloads),
        Check("pod_health", STANDARD, sweep.pod_health),
        Check("storage", STANDARD, sweep.storage),
        Check("pod_stability", STANDARD, core.pod_stability),
        # FULL depth: observed state, recorded and never graded. These run last
        # so a fact can never delay a verdict, and they are separate functions
        # from the checks above so that reading the registry still answers "what
        # can fail this run" without having to read the bodies.
        Check("hardware", FULL, facts.host),
        Check("nodes", FULL, facts.nodes),
        Check("monitoring", FULL, facts.monitoring),
        Check("argocd", FULL, facts.argocd),
        Check("tailscale", FULL, facts.tailscale),
        Check("traefik", FULL, facts.traefik),
        Check("kyverno", FULL, facts.kyverno),
        Check("karpenter", FULL, facts.karpenter),
        Check("external_secrets", FULL, facts.external_secrets),
        Check("longhorn", FULL, facts.longhorn),
        Check("storage", FULL, facts.storage),
    ]
