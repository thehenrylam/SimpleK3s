"""Workload readiness.

WHY NOT `kubectl rollout status`. It answers "has the controller converged on
what you asked for", which is TRUE for a Deployment scaled to zero — you asked
for none, you have none. Verified live: Grafana scaled to 0 produced
`rollout status => SUCCESS` and a fully green report while Grafana was entirely
absent (#111).

Readiness here means: at least one replica is wanted, and at least that many are
ready.
"""

from . import kube

_KINDS = {
    "deployment": ("spec.replicas", "status.readyReplicas"),
    "statefulset": ("spec.replicas", "status.readyReplicas"),
    "daemonset": ("status.desiredNumberScheduled", "status.numberReady"),
}


def state(kind, namespace, name):
    """Return (ready: bool, message: str) for one workload.

    Raises Unavailable if the workload could not be inspected — distinct from
    the workload being absent, which is a real answer the caller may treat as
    "not deployed".
    """
    kind = kind.lower()
    if kind not in _KINDS:
        raise ValueError(f"unsupported kind {kind!r}")
    want_path, have_path = _KINDS[kind]

    obj = kube.run_json(["-n", namespace, "get", kind, name])
    want = kube.dig(obj, want_path)
    have = kube.dig(obj, have_path) or 0

    ref = f"{namespace}/{kind}/{name}"
    if want is None:
        raise kube.Unavailable(f"{ref} did not report a replica count")
    if want < 1:
        # The zero-replica blind spot, stated as a verdict rather than tolerated.
        return False, f"{ref} is scaled to 0 — it is not running"
    if have < want:
        return False, f"{ref} has {have}/{want} replicas ready"
    return True, f"{ref} has {have}/{want} replicas ready"


def present(kind, namespace, name):
    """Whether the workload exists at all."""
    return kube.exists(["-n", namespace, "get", kind.lower(), name])
