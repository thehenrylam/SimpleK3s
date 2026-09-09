"""Health definitions — one per subsystem, in one place.

Each check receives a recorder already bound to its section, so it states what
it observed and never names the section itself.

Vertical slice: core plus two subsystems. The rest follow the same shape.
"""

from . import kube, workloads
from .registry import FULL, QUICK, STANDARD, Check

# ─── Core ────────────────────────────────────────────────────────────────────


def k3s_api(rec):
    kube.run(["get", "--raw=/readyz"])
    rec.passed("K3s API is reachable")


def nodes_ready(rec):
    items = kube.run_json(["get", "nodes"]).get("items") or []
    if not items:
        # Reaching here means the query SUCCEEDED and still returned nothing.
        # That is its own anomaly, not a healthy cluster (#156).
        rec.failed("The cluster reported no nodes at all")
        return

    not_ready = []
    for node in items:
        name = node.get("metadata", {}).get("name", "<unknown>")
        conds = node.get("status", {}).get("conditions") or []
        ready = next((c.get("status") for c in conds if c.get("type") == "Ready"), None)
        if ready != "True":
            not_ready.append(f"{name} (Ready={ready})")

    if not_ready:
        rec.failed(f"{len(not_ready)} of {len(items)} nodes are not Ready", "\n".join(not_ready))
    else:
        rec.passed(f"All {len(items)} nodes are Ready")


def kube_system(rec):
    for name in ("coredns", "local-path-provisioner"):
        rec.verdict(*workloads.state("deployment", "kube-system", name))


# ─── Traefik ─────────────────────────────────────────────────────────────────


def traefik(rec):
    if not workloads.present("deployment", "kube-system", "traefik"):
        rec.skipped("kube-system/traefik not present (subsystem not enabled)")
        return
    rec.verdict(*workloads.state("deployment", "kube-system", "traefik"))

    for ref in ("middleware/https-redirect", "ingressroute/web-http-catchall-redirect"):
        kind, name = ref.split("/")
        exists = kube.exists(["-n", "kube-system", "get", kind, name])
        rec.verdict(exists, f"kube-system/{ref} {'exists' if exists else 'is missing'}")


# ─── Monitoring ──────────────────────────────────────────────────────────────

_MONITORING = [
    ("deployment", "prometheus-kube-prometheus-operator"),
    ("deployment", "prometheus-grafana"),
    ("statefulset", "prometheus-prometheus-kube-prometheus-prometheus"),
    ("statefulset", "alertmanager-prometheus-kube-prometheus-alertmanager"),
]


def monitoring(rec):
    if not kube.exists(["get", "ns", "monitoring"]):
        rec.skipped("namespace 'monitoring' not present (application not enabled)")
        return
    for kind, name in _MONITORING:
        rec.verdict(*workloads.state(kind, "monitoring", name))


def monitoring_facts(rec):
    """Full depth reports observed state; it does not grade it. The answer sheet
    lives outside this tool and consumes what is reported here."""
    if not kube.exists(["get", "ns", "monitoring"]):
        return
    pods = kube.run_json(["-n", "monitoring", "get", "pods"]).get("items") or []
    rec.fact(
        "pods",
        [
            {
                "name": p.get("metadata", {}).get("name"),
                "phase": p.get("status", {}).get("phase"),
                "restarts": sum(
                    c.get("restartCount", 0)
                    for c in (p.get("status", {}).get("containerStatuses") or [])
                ),
            }
            for p in pods
        ],
    )


def build_registry():
    """The complete set of checks, in report order.

    Explicit by design: what runs, in what order, and at what depth is readable
    here rather than inferred from decorator execution during import.
    """
    return [
        Check("k3s_api", QUICK, k3s_api),
        Check("nodes", QUICK, nodes_ready),
        Check("kube_system", QUICK, kube_system),
        Check("traefik", STANDARD, traefik),
        Check("monitoring", STANDARD, monitoring),
        Check("monitoring", FULL, monitoring_facts),
    ]
