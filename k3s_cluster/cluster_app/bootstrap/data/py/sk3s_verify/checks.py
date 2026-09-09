"""Health definitions — one per subsystem, in one place.

Vertical slice: core + two subsystems. The rest follow the same shape and are
ported in the same commit series.
"""

from . import kube, workloads
from .registry import FULL, QUICK, STANDARD, check

# ─── Core ────────────────────────────────────────────────────────────────────


@check("k3s_api", depth=QUICK)
def k3s_api(rec):
    kube.run(["get", "--raw=/readyz"])
    rec.passed("k3s_api", "K3s API is reachable")


@check("nodes", depth=QUICK)
def nodes_ready(rec):
    obj = kube.run_json(["get", "nodes"])
    items = obj.get("items") or []
    if not items:
        # Reaching here means the query SUCCEEDED and still returned nothing.
        # That is its own anomaly, not a healthy cluster (#156).
        rec.failed("nodes", "The cluster reported no nodes at all")
        return

    not_ready = []
    for node in items:
        name = node.get("metadata", {}).get("name", "<unknown>")
        conds = node.get("status", {}).get("conditions") or []
        ready = next((c.get("status") for c in conds if c.get("type") == "Ready"), None)
        if ready != "True":
            not_ready.append(f"{name} (Ready={ready})")

    if not_ready:
        rec.failed(
            "nodes",
            f"{len(not_ready)} of {len(items)} nodes are not Ready",
            "\n".join(not_ready),
        )
    else:
        rec.passed("nodes", f"All {len(items)} nodes are Ready")


@check("kube_system", depth=QUICK)
def kube_system(rec):
    for name in ("coredns", "local-path-provisioner"):
        ok, message = workloads.state("deployment", "kube-system", name)
        (rec.passed if ok else rec.failed)("kube_system", message)


# ─── Traefik ─────────────────────────────────────────────────────────────────


@check("traefik", depth=STANDARD)
def traefik(rec):
    if not workloads.present("deployment", "kube-system", "traefik"):
        rec.skipped("traefik", "kube-system/traefik not present (subsystem not enabled)")
        return
    ok, message = workloads.state("deployment", "kube-system", "traefik")
    (rec.passed if ok else rec.failed)("traefik", message)

    for ref in ("middleware/https-redirect", "ingressroute/web-http-catchall-redirect"):
        kind, name = ref.split("/")
        if kube.exists(["-n", "kube-system", "get", kind, name]):
            rec.passed("traefik", f"kube-system/{ref} exists")
        else:
            rec.failed("traefik", f"kube-system/{ref} is missing")


# ─── Monitoring ──────────────────────────────────────────────────────────────

_MONITORING = [
    ("deployment", "prometheus-kube-prometheus-operator"),
    ("deployment", "prometheus-grafana"),
    ("statefulset", "prometheus-prometheus-kube-prometheus-prometheus"),
    ("statefulset", "alertmanager-prometheus-kube-prometheus-alertmanager"),
]


@check("monitoring", depth=STANDARD)
def monitoring(rec):
    if not kube.exists(["get", "ns", "monitoring"]):
        rec.skipped("monitoring", "namespace 'monitoring' not present (application not enabled)")
        return
    for kind, name in _MONITORING:
        ok, message = workloads.state(kind, "monitoring", name)
        (rec.passed if ok else rec.failed)("monitoring", message)


@check("monitoring", depth=FULL)
def monitoring_facts(rec):
    """Full depth reports observed state; it does not grade it. The answer sheet
    lives outside this tool and consumes what we report here."""
    if not kube.exists(["get", "ns", "monitoring"]):
        return
    obj = kube.run_json(["-n", "monitoring", "get", "pods"])
    rec.fact(
        "monitoring.pods",
        [
            {
                "name": p.get("metadata", {}).get("name"),
                "phase": p.get("status", {}).get("phase"),
                "restarts": sum(
                    c.get("restartCount", 0)
                    for c in (p.get("status", {}).get("containerStatuses") or [])
                ),
            }
            for p in (obj.get("items") or [])
        ],
    )
