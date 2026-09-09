"""Observed state, collected at FULL depth and never graded.

WHY FACTS ARE NOT CHECKS. A check answers a question this tool is willing to
fail a deploy over. A fact is a reading — a disk at 86%, a Thanos store list, an
HTTP status — where the threshold is somebody else's business. Folding the two
together is what produced an "answer sheet" that had to be maintained in lockstep
with the prober; keeping them apart lets `sk3s status --depth full` report what
is honestly present and lets a test decide what "good" means.

So NOTHING HERE RETURNS A VERDICT. Collectors record facts only, and each one
catches its own failures and records them as a value: a probe that could not
connect reports that it could not connect, with the reason. The runner's
exception guard stays behind them as a backstop for a genuinely broken
collector, not as the normal path for an unreachable endpoint.

Facts are namespaced under their section by the recorder, so a collector bound
to "monitoring" cannot write a key that collides with one bound to "traefik".
"""

from .. import hardware, http, kube

# ─── Helpers ─────────────────────────────────────────────────────────────────


def _listing(resource, namespace=None):
    """Names of every object of a kind, or the reason they could not be listed.

    A missing CRD makes kubectl fail, which is a real and useful answer here
    ("this subsystem is not installed") rather than something to hide.
    """
    args = ["-n", namespace, "get", resource] if namespace else ["get", resource, "-A"]
    try:
        items = kube.run_json(args).get("items") or []
    except kube.Unavailable as exc:
        return {"error": str(exc)}
    names = []
    for obj in items:
        meta = obj.get("metadata", {})
        namespaced = meta.get("namespace")
        name = meta.get("name") or "?"
        names.append(f"{namespaced}/{name}" if namespaced else name)
    return {"total": len(names), "names": sorted(names)}


def _endpoint_fact(response, **extra):
    """Flatten a probe response into the shape every endpoint fact shares."""
    return {
        "url": response["url"],
        "status": response["status"],
        "error": response["error"],
        **extra,
    }


# ─── Hardware ────────────────────────────────────────────────────────────────


def host(rec):
    """Per-node metrics. The only facts that legitimately differ between nodes."""
    try:
        for key, value in hardware.snapshot().items():
            rec.fact(key, value)
    except (OSError, KeyError, ValueError) as exc:
        rec.fact("error", repr(exc))


# ─── Monitoring endpoints ────────────────────────────────────────────────────

GRAFANA_SERVICE = ("monitoring", "prometheus-grafana")
THANOS_QUERY_SERVICE = ("monitoring", "thanos-query")
PROMETHEUS_PORT = 9090

# Services in the monitoring namespace that carry :9090 but are not the queryable
# Prometheus: the operator's own endpoints and the headless governing Services.
_NOT_PROMETHEUS = ("operated", "operator", "node-exporter")


def prometheus_service():
    """Name of the Service that actually answers Prometheus queries.

    Matched by port rather than by name, because the release prefix is chosen by
    whoever installed the chart and hard-coding it would break on rename.
    """
    try:
        items = kube.run_json(["-n", "monitoring", "get", "svc"]).get("items") or []
    except kube.Unavailable:
        return None
    for obj in items:
        name = obj.get("metadata", {}).get("name") or ""
        if any(token in name for token in _NOT_PROMETHEUS):
            continue
        spec = obj.get("spec", {})
        cluster_ip = spec.get("clusterIP")
        if not cluster_ip or cluster_ip == "None":
            continue
        if any(p.get("port") == PROMETHEUS_PORT for p in spec.get("ports") or []):
            return name
    return None


def _grafana():
    # /api/health also reports the database. Grafana that cannot reach its
    # database still reports Ready to Kubernetes and serves a broken UI.
    response = http.probe(*GRAFANA_SERVICE, "/api/health")
    body = http.json_body(response) or {}
    return _endpoint_fact(response, database=body.get("database"), version=body.get("version"))


def prometheus_route_prefix():
    """Prometheus serves under spec.routePrefix when it sits behind a path-based
    Ingress, as it does here (/prometheus).

    Probing "/-/healthy" without it gets a 404 from a completely healthy server.
    That is worse than no reading: a fact nobody grades is still a fact somebody
    believes, and "Prometheus returned 404" reads as an outage.
    """
    try:
        items = kube.run_json(["get", "prometheuses", "-A"]).get("items") or []
    except kube.Unavailable:
        return ""
    for obj in items:
        prefix = (obj.get("spec", {}).get("routePrefix") or "").rstrip("/")
        if prefix:
            return prefix
    return ""


def _prometheus():
    name = prometheus_service()
    if name is None:
        return {"error": "no queryable Prometheus service found in monitoring"}
    prefix = prometheus_route_prefix()
    out = {"service": name, "route_prefix": prefix}
    for label, path in (("healthy", "/-/healthy"), ("ready", "/-/ready")):
        response = http.probe("monitoring", name, f"{prefix}{path}", port=PROMETHEUS_PORT)
        out[label] = _endpoint_fact(response)
    return out


def _thanos():
    out = {}
    for label, path in (("healthy", "/-/healthy"), ("ready", "/-/ready")):
        response = http.probe(*THANOS_QUERY_SERVICE, path, port=PROMETHEUS_PORT)
        out[label] = _endpoint_fact(response)

    # /api/v1/stores groups connected StoreAPIs by component. A healthy setup
    # lists the Prometheus *sidecar*; its absence is the discovery misconfig that
    # leaves Grafana with no recent data while every pod looks fine.
    response = http.probe(*THANOS_QUERY_SERVICE, "/api/v1/stores", port=PROMETHEUS_PORT)
    payload = http.json_body(response) or {}
    data = payload.get("data") or {}
    by_component = {component: len(entries or []) for component, entries in data.items()}
    out["stores"] = _endpoint_fact(
        response,
        by_component=by_component,
        total=sum(by_component.values()),
        sidecar_connected=by_component.get("sidecar", 0) >= 1,
    )
    return out


def monitoring(rec):
    rec.fact("grafana", _grafana())
    rec.fact("prometheus", _prometheus())
    rec.fact("thanos", _thanos())
    rec.fact("alerts", _listing("prometheusrules", namespace="monitoring"))


# ─── ArgoCD ──────────────────────────────────────────────────────────────────


def argocd_root_path():
    """argocd-server serves under server.rootpath when exposed path-based behind
    Traefik, as it is here (/argocd). Without it every probe gets a 404."""
    try:
        params = kube.run_json(["-n", "argocd", "get", "cm", "argocd-cmd-params-cm"])
    except kube.Unavailable:
        return ""
    return ((params.get("data") or {}).get("server.rootpath") or "").rstrip("/")


def argocd(rec):
    # Probed WITHOUT following redirects. A registered OIDC login route answers
    # 3xx toward the IdP; an unregistered one falls through to the SPA, which
    # returns 200 for any path. Following the redirect would erase the only
    # difference between "SSO works" and "SSO is dead".
    root = argocd_root_path()
    response = http.probe("argocd", "argocd-server", f"{root}/auth/login", follow_redirects=False)
    location = None
    if response["status"] in (301, 302, 303, 307, 308):
        location = "redirect issued"
    rec.fact("login_route", _endpoint_fact(response, redirect=location, root_path=root))
    rec.fact("applications", _listing("applications", namespace="argocd"))


# ─── Tailscale ───────────────────────────────────────────────────────────────

ENTRYPOINT_INGRESS = "tailnet-entrypoint"


def entrypoint_ingress():
    """The tailnet entrypoint Ingress, found by NAME across all namespaces.

    Deliberately not looked up in a fixed namespace. It fronts Traefik rather
    than the operator, so it lives wherever Traefik does (kube-system today) —
    not in the tailscale namespace, which is the obvious wrong guess. Searching
    by name survives it moving.
    """
    try:
        items = kube.run_json(["get", "ingress", "-A"]).get("items") or []
    except kube.Unavailable as exc:
        return None, str(exc)
    for obj in items:
        if obj.get("metadata", {}).get("name") == ENTRYPOINT_INGRESS:
            return obj, None
    return None, f"no Ingress named {ENTRYPOINT_INGRESS} in any namespace"


def _backend_of(ingress):
    """The Service an Ingress forwards to, as (namespace, name, port)."""
    namespace = ingress.get("metadata", {}).get("namespace") or ""
    for rule in ingress.get("spec", {}).get("rules") or []:
        for path in (rule.get("http") or {}).get("paths") or []:
            service = (path.get("backend") or {}).get("service") or {}
            if service.get("name"):
                return {
                    "namespace": namespace,
                    "service": service["name"],
                    "port": (service.get("port") or {}).get("number"),
                }
    return None


def tailscale(rec):
    ingress, error = entrypoint_ingress()
    if ingress is None:
        rec.fact("entrypoint", {"error": error})
        rec.fact("backend", {"error": error})
        return

    loadbalancer = ingress.get("status", {}).get("loadBalancer", {}).get("ingress") or []
    rec.fact(
        "entrypoint",
        {
            "namespace": ingress.get("metadata", {}).get("namespace"),
            "class": ingress.get("spec", {}).get("ingressClassName"),
            "hostnames": [entry.get("hostname", "") for entry in loadbalancer],
        },
    )

    backend = _backend_of(ingress)
    if backend is None:
        rec.fact("backend", {"error": "ingress defines no backend service"})
        return

    # Nodes are not on the tailnet, so probe the leg we CAN reach: the backend
    # Service the Ingress points at. ANY HTTP status proves Traefik's tsnet
    # listener is up — even a 404 for an unmatched Host. Only a transport
    # failure means the path is broken.
    response = http.probe(
        backend["namespace"],
        backend["service"],
        "/",
        port=backend["port"],
        follow_redirects=False,
    )
    rec.fact("backend", _endpoint_fact(response, service=backend["service"]))


# ─── Inventories ─────────────────────────────────────────────────────────────
#
# Counts and names, not whole objects. What an operator wants in hand when a
# named check fails is "which ones exist"; the object bodies are already a
# kubectl away and would dominate the report's size.


def traefik(rec):
    rec.fact("ingressroutes", _listing("ingressroutes"))
    rec.fact("middlewares", _listing("middlewares"))


def kyverno(rec):
    rec.fact("cluster_policies", _listing("clusterpolicies"))
    rec.fact("policies", _listing("policies"))


def karpenter(rec):
    rec.fact("nodepools", _listing("nodepools"))
    rec.fact("nodeclaims", _listing("nodeclaims"))
    rec.fact("ec2nodeclasses", _listing("ec2nodeclasses"))


def external_secrets(rec):
    rec.fact("external_secrets", _listing("externalsecrets"))
    # Both kinds. Reporting only the cluster-scoped one was accurate and
    # useless here: this deployment binds namespaced SecretStores, so the
    # cluster-scoped total is legitimately 0 and reads as "nothing configured".
    rec.fact("cluster_secret_stores", _listing("clustersecretstores"))
    rec.fact("secret_stores", _listing("secretstores"))


def longhorn(rec):
    rec.fact("volumes", _listing("volumes", namespace="longhorn-system"))
    rec.fact("nodes", _listing("nodes.longhorn.io", namespace="longhorn-system"))


def storage(rec):
    rec.fact("claims", _listing("pvc"))
    rec.fact("classes", _listing("storageclasses"))


def nodes(rec):
    """Node inventory: what the cluster is made of, and what each node runs."""
    try:
        items = kube.run_json(["get", "nodes"]).get("items") or []
    except kube.Unavailable as exc:
        rec.fact("inventory", {"error": str(exc)})
        return
    inventory = []
    for node in items:
        meta = node.get("metadata", {})
        status = node.get("status", {})
        info = status.get("nodeInfo", {})
        capacity = status.get("capacity", {})
        inventory.append(
            {
                "name": meta.get("name"),
                "labels": {
                    key: value
                    for key, value in (meta.get("labels") or {}).items()
                    if key.startswith("node-role") or key == "karpenter.sh/nodepool"
                },
                "kubelet": info.get("kubeletVersion"),
                "os": info.get("osImage"),
                "arch": info.get("architecture"),
                "cpu": capacity.get("cpu"),
                "memory": capacity.get("memory"),
            }
        )
    rec.fact("inventory", sorted(inventory, key=lambda entry: entry["name"] or ""))
