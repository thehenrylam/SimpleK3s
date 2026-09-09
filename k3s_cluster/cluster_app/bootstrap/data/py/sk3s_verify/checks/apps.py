"""Application health: ArgoCD and the monitoring stack."""

import base64

from .. import kube, workloads

_MONITORING = [
    ("deployment", "prometheus-kube-prometheus-operator"),
    ("deployment", "prometheus-grafana"),
    ("statefulset", "prometheus-prometheus-kube-prometheus-prometheus"),
    ("statefulset", "alertmanager-prometheus-kube-prometheus-alertmanager"),
]


# ─── ArgoCD ──────────────────────────────────────────────────────────────────


def oidc_state():
    """Whether argocd-server's OIDC HTTP routes are registered.

    Returns "current", "stale", or "unknown".

    WHY A TIMESTAMP COMPARISON AND NOT AN HTTP PROBE (#95, #145). argocd-server
    mounts /auth/login and /auth/callback ONCE at startup, and only if SSO
    resolves as configured at that instant. The defect is purely causal: the
    server booted before External-Secrets populated argocd-oidc. Comparing the
    oldest running pod's start time against the secret's creation time tests
    that cause directly.

    Probing the route was rejected: its negative response is unverified, and if
    an unregistered /auth/login returns the UI's SPA fallback rather than a 404,
    the probe reports "registered" for a server with dead SSO. A probe that can
    be wrong in the "looks fine" direction is worse than none.

    Strictly-after is the only "current". Timestamps carry second granularity,
    so a tie leaves room for the pod to have started just before the secret
    landed, and at that boundary the cheap error is a needless restart.
    """
    try:
        secret = kube.run_json(["-n", "argocd", "get", "secret", "argocd-oidc"])
        secret_ts = secret.get("metadata", {}).get("creationTimestamp")
        if not secret_ts:
            return "unknown"

        deploy = kube.run_json(["-n", "argocd", "get", "deployment", "argocd-server"])
        labels = deploy.get("spec", {}).get("selector", {}).get("matchLabels") or {}
        if not labels:
            return "unknown"
        selector = ",".join(f"{k}={v}" for k, v in sorted(labels.items()))

        pods = (
            kube.run_json(
                [
                    "-n",
                    "argocd",
                    "get",
                    "pods",
                    "-l",
                    selector,
                    "--field-selector=status.phase=Running",
                ]
            ).get("items")
            or []
        )
        starts = [p.get("status", {}).get("startTime") for p in pods]
        starts = [s for s in starts if s]
        if not starts:
            return "unknown"
    except kube.Unavailable:
        return "unknown"

    # The OLDEST running pod decides: if any live replica predates the secret it
    # is serving 404s on the SSO routes, and a newer sibling does not fix the
    # requests that land on it. RFC3339 UTC compares correctly as strings.
    return "current" if min(starts) > secret_ts else "stale"


def argocd(rec):
    if not kube.exists(["get", "ns", "argocd"]):
        rec.skipped("namespace 'argocd' not present (application not enabled)")
        return
    rec.verdict(*workloads.state("deployment", "argocd", "argocd-server"))

    issuer = ""
    try:
        secret = kube.run_json(["-n", "argocd", "get", "secret", "argocd-oidc"])
        raw = (secret.get("data") or {}).get("oidc.cognito.issuer", "")
        issuer = base64.b64decode(raw).decode(errors="replace").strip() if raw else ""
    except kube.Unavailable:
        issuer = ""
    rec.verdict(
        bool(issuer),
        "argocd/argocd-oidc secret has OIDC issuer populated"
        if issuer
        else "argocd/argocd-oidc secret is missing or empty (ESO may still be syncing)",
    )

    # A populated secret is NOT enough — see oidc_state.
    state = oidc_state()
    if state == "current":
        rec.passed("argocd-server has OIDC routes registered (started after the secret)")
    elif state == "stale":
        rec.failed(
            "argocd-server predates the argocd-oidc secret; "
            "SSO routes are not registered (needs a restart — see #95)"
        )
    else:
        rec.skipped("OIDC route registration could not be determined")


# ─── Monitoring ──────────────────────────────────────────────────────────────


def monitoring(rec):
    if not kube.exists(["get", "ns", "monitoring"]):
        rec.skipped("namespace 'monitoring' not present (application not enabled)")
        return
    for kind, name in _MONITORING:
        rec.verdict(*workloads.state(kind, "monitoring", name))
