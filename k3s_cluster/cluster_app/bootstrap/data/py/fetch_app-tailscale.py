#!/usr/bin/env python3

# Builtin Modules
import importlib.util
import json
import os
import sys

_dir = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "fetch_UTILITIES", os.path.join(_dir, "fetch_UTILITIES.py")
)
_utils = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_utils)
emit = _utils.emit
get_resource = _utils.get_resource
get_resources = _utils.get_resources
get_ready_condition = _utils.get_ready_condition
http_get = _utils.http_get
run_command = _utils.run_command

NS = "tailscale"
# Names come from the tailscale subsystem manifests (cluster_app/tailscale/data/):
# the operator HelmChart materializes deploy/operator, the ExternalSecret
# materializes the operator-oauth Secret, and the tailnet entry point is the
# `tailnet-entrypoint` Ingress fronting Traefik's plaintext tsnet entrypoint.
OPERATOR_DEPLOY = "operator"
OAUTH_SECRET = "operator-oauth"
OAUTH_EXTERNAL_SECRET = "tailscale-operator-oauth"
SECRET_STORE = "parameterstore"
INGRESS_CLASS = "tailscale"
ENTRYPOINT_INGRESS = "tailnet-entrypoint"
# Labels the operator stamps on the proxy StatefulSet it creates for the Ingress
# (same selector sub_apply_tailscale.sh gates the bootstrap on).
PROXY_PARENT_LABELS = {
    "tailscale.com/parent-resource": ENTRYPOINT_INGRESS,
    "tailscale.com/parent-resource-type": "ingress",
}


def _check_operator(errors: list) -> dict:
    # The operator reconciles Ingresses into proxy devices; nothing below works
    # without it. Ready = the Deployment's rollout has fully converged.
    deploy, err = get_resource("deploy", NS, OPERATOR_DEPLOY)
    if err or not deploy:
        errors.append({"resource": f"deploy/{OPERATOR_DEPLOY}", "error": err or "not found"})
        return {"ready": False, "desired": None, "available": None}
    spec_replicas = deploy.get("spec", {}).get("replicas")
    desired = 1 if spec_replicas is None else spec_replicas
    status = deploy.get("status", {})
    generation_synced = status.get("observedGeneration", 0) >= deploy.get("metadata", {}).get(
        "generation", 0
    )
    available = status.get("availableReplicas", 0)
    updated = status.get("updatedReplicas", 0)
    ready = generation_synced and available == desired and updated == desired
    return {"ready": ready, "desired": desired, "available": available}


def _check_oauth_secret(errors: list) -> dict:
    # The operator authenticates to the tailnet with the OAuth client in this
    # Secret. Assert both keys exist AND are non-empty — an ExternalSecret can
    # materialize the Secret with blank values if the Parameter Store JSON is
    # malformed. Values are never decoded or reported (presence only).
    secret, err = get_resource("secret", NS, OAUTH_SECRET)
    if err or not secret:
        errors.append({"resource": f"secret/{OAUTH_SECRET}", "error": err or "not found"})
        return {"ok": False, "client_id_present": False, "client_secret_present": False}
    data = secret.get("data", {})
    client_id_present = bool(data.get("client_id"))
    client_secret_present = bool(data.get("client_secret"))
    return {
        "ok": client_id_present and client_secret_present,
        "client_id_present": client_id_present,
        "client_secret_present": client_secret_present,
    }


def _check_oauth_external_secret(errors: list) -> dict:
    # Same rule as fetch_app-external-secrets.py: only reason "SecretSynced"
    # proves the OAuth client was actually pulled from Parameter Store —
    # Ready=True alone can be the #95 false positive.
    es, err = get_resource("externalsecret", NS, OAUTH_EXTERNAL_SECRET)
    if err or not es:
        errors.append(
            {"resource": f"externalsecret/{OAUTH_EXTERNAL_SECRET}", "error": err or "not found"}
        )
        return {"synced": False, "reason": "not found"}
    cond = get_ready_condition(es)
    return {"synced": cond["ready"] and cond["reason"] == "SecretSynced", "reason": cond["reason"]}


def _check_secret_store(errors: list) -> dict:
    # SecretStore Ready (reason "Valid") = the ESO->Parameter Store connection
    # (AWS auth + region) is wired for this namespace.
    store, err = get_resource("secretstore", NS, SECRET_STORE)
    if err or not store:
        errors.append({"resource": f"secretstore/{SECRET_STORE}", "error": err or "not found"})
        return {"ready": False, "reason": "not found"}
    cond = get_ready_condition(store)
    return {"ready": cond["ready"], "reason": cond["reason"]}


def _check_ingressclass(errors: list) -> dict:
    # The operator registers the `tailscale` IngressClass that the entry point
    # (and any internal-exposure Ingress) references. IngressClass is
    # cluster-scoped, so list-and-filter instead of a namespaced get.
    payload = get_resources("ingressclass")
    if "error" in payload:
        errors.append({"resource": "ingressclass", "error": payload["error"]})
        return {"ok": False, "controller": None}
    for obj in payload.get("items", []):
        if obj.get("metadata", {}).get("name") == INGRESS_CLASS:
            return {"ok": True, "controller": obj.get("spec", {}).get("controller")}
    return {"ok": False, "controller": None}


def _check_proxyclasses(errors: list) -> tuple:
    # ProxyClass sizes every operator-created proxy StatefulSet. If it is not
    # Ready the operator (v1.98.4) wedges the Ingress reconcile and never
    # creates the proxy device — the race sub_apply_tailscale.sh gates against.
    # Name-agnostic like the apply script: at least one must exist, all Ready.
    payload = get_resources("proxyclasses")
    entries = []
    if "error" in payload:
        errors.append({"resource": "proxyclasses", "error": payload["error"]})
        return entries, False
    for obj in payload.get("items", []):
        ready, reason = False, "NoProxyClassReadyCondition"
        for cond in obj.get("status", {}).get("conditions", []):
            if cond.get("type") == "ProxyClassReady":
                ready = cond.get("status") == "True"
                reason = cond.get("reason", "")
                break
        entries.append(
            {"name": obj.get("metadata", {}).get("name", ""), "ready": ready, "reason": reason}
        )
    all_ready = bool(entries) and all(e["ready"] for e in entries)
    return entries, all_ready


def _check_entrypoint_ingress(errors: list) -> dict:
    # The single tailnet device fronting Traefik. Namespace is Traefik's (an
    # Ingress backend is same-namespace), so locate it by name across namespaces.
    # `hostname_ok` is the strongest signal available from inside the cluster:
    # the operator only stamps status.loadBalancer with the *.ts.net MagicDNS
    # hostname once the proxy device is registered on the tailnet.
    payload = get_resources("ingress")
    if "error" in payload:
        errors.append({"resource": "ingress", "error": payload["error"]})
        return {"found": False, "class_ok": False, "hostname_ok": False}
    ingress = next(
        (
            obj
            for obj in payload.get("items", [])
            if obj.get("metadata", {}).get("name") == ENTRYPOINT_INGRESS
        ),
        None,
    )
    if ingress is None:
        errors.append({"resource": f"ingress/{ENTRYPOINT_INGRESS}", "error": "not found"})
        return {"found": False, "class_ok": False, "hostname_ok": False}

    class_ok = ingress.get("spec", {}).get("ingressClassName") == INGRESS_CLASS
    hostnames = [
        entry.get("hostname", "")
        for entry in ingress.get("status", {}).get("loadBalancer", {}).get("ingress", [])
    ]
    hostname_ok = any(h.endswith(".ts.net") for h in hostnames)

    backend = {}
    for rule in ingress.get("spec", {}).get("rules", []):
        for path in rule.get("http", {}).get("paths", []):
            svc = path.get("backend", {}).get("service", {})
            if svc.get("name"):
                backend = {
                    "namespace": ingress.get("metadata", {}).get("namespace", ""),
                    "service": svc.get("name"),
                    "port": svc.get("port", {}).get("number"),
                }
                break
        if backend:
            break

    return {
        "found": True,
        "namespace": ingress.get("metadata", {}).get("namespace", ""),
        "class_ok": class_ok,
        "hostname_ok": hostname_ok,
        "hostnames": hostnames,
        "backend": backend,
    }


def _check_backend_http(entrypoint: dict, errors: list) -> dict:
    # The device forwards tailnet traffic to Traefik's dedicated plaintext tsnet
    # entrypoint. Nodes are not on the tailnet, so probe the leg we CAN reach:
    # the backend Service the Ingress points at. Any HTTP status (even Traefik's
    # 404 for an unmatched Host) proves the tsnet listener is up; only a
    # transport failure (refused/timeout) means the path is broken.
    backend = entrypoint.get("backend") or {}
    if not backend.get("service") or not backend.get("port"):
        return {"ok": False, "status": None, "url": None, "reason": "no ingress backend"}
    svc, err = get_resource("svc", backend["namespace"], backend["service"])
    if err or not svc:
        errors.append({"resource": f"svc/{backend['service']}", "error": err or "not found"})
        return {"ok": False, "status": None, "url": None, "reason": "backend service not found"}
    cip = svc.get("spec", {}).get("clusterIP")
    svc_ports = svc.get("spec", {}).get("ports", [])
    port_defined = any(p.get("port") == backend["port"] for p in svc_ports)
    if not cip or not port_defined:
        return {"ok": False, "status": None, "url": None, "reason": "backend port not on service"}
    url = f"http://{cip}:{backend['port']}/"
    resp = http_get(url, follow_redirects=False)
    if resp["error"]:
        errors.append({"resource": f"tsnet entrypoint {url}", "error": resp["error"]})
        return {"ok": False, "status": None, "url": url, "reason": "no HTTP response"}
    return {"ok": True, "status": resp["status"], "url": url, "reason": None}


def _check_tls_cert(entrypoint: dict, errors: list) -> dict:
    # Tailscale terminates HTTPS on the device with a Let's Encrypt cert and
    # stores the issued cert in the proxy's state Secret as a `<fqdn>.crt` data
    # key. No such key while the MagicDNS hostname is assigned means TLS
    # handshakes to the tailnet URL hang even though every workload is healthy —
    # e.g. LE's 5-certs-per-hostname-per-168h limit after repeated cluster
    # rebuilds. Only key NAMES are inspected; no secret values are read.
    hostnames = [h for h in entrypoint.get("hostnames") or [] if h.endswith(".ts.net")]
    if not hostnames:
        return {"issued": False, "message": "no MagicDNS hostname on the entrypoint Ingress"}

    result = run_command(f"kubectl -n {NS} get secrets -o json")
    if not result.ok:
        errors.append({"resource": "secrets", "error": result.stderr or result.stdout})
        return {"issued": False, "message": "could not list tailscale secrets"}
    try:
        secrets = json.loads(result.stdout) if result.stdout else {"items": []}
    except json.JSONDecodeError as exc:
        errors.append({"resource": "secrets", "error": f"failed to parse json: {exc}"})
        return {"issued": False, "message": "could not parse tailscale secrets"}

    wanted = {f"{h}.crt" for h in hostnames}
    for obj in secrets.get("items", []):
        if wanted & set(obj.get("data", {}) or {}):
            return {"issued": True, "message": None}

    # Not issued: pull the proxy's last ACME error so the report says WHY
    # (rate-limited, unreachable, ...). Field is named "message" on purpose —
    # the orchestrator strips it before cross-node agreement, so log noise
    # (timestamps) can't cause spurious disagreement.
    sel = ",".join(f"{k}={v}" for k, v in PROXY_PARENT_LABELS.items())
    logs = run_command(f"kubectl -n {NS} logs -l {sel} --tail=200", timeout=30)
    message = "cert not present in proxy state; no ACME error found in recent logs"
    if logs.ok:
        acme_errors = [ln for ln in logs.stdout.splitlines() if "getCertPEM" in ln]
        if acme_errors:
            message = acme_errors[-1][-500:]
    return {"issued": False, "message": message}


def _check_proxy_statefulsets(errors: list) -> tuple:
    # The operator materializes the tailnet device as a StatefulSet in the
    # tailscale namespace. Missing = the device was never created (the wedge
    # wait_for_proxy guards against); not-ready = the proxy pod is not running.
    payload = get_resources("statefulsets")
    entries = []
    if "error" in payload:
        errors.append({"resource": "statefulsets", "error": payload["error"]})
        return entries, False
    for obj in payload.get("items", []):
        meta = obj.get("metadata", {})
        labels = meta.get("labels", {})
        if meta.get("namespace") != NS:
            continue
        if any(labels.get(k) != v for k, v in PROXY_PARENT_LABELS.items()):
            continue
        spec_replicas = obj.get("spec", {}).get("replicas")
        desired = 1 if spec_replicas is None else spec_replicas
        status = obj.get("status", {})
        generation_synced = status.get("observedGeneration", 0) >= meta.get("generation", 0)
        rollout_done = status.get("currentRevision") == status.get("updateRevision")
        ready = (
            generation_synced
            and rollout_done
            and status.get("readyReplicas", 0) == desired
            and status.get("updatedReplicas", 0) == desired
        )
        entries.append(
            {
                "name": meta.get("name", ""),
                "desired": desired,
                "ready_replicas": status.get("readyReplicas", 0),
                "ready": ready,
            }
        )
    all_ready = bool(entries) and all(e["ready"] for e in entries)
    return entries, all_ready


def _not_deployed() -> dict:
    # The tailscale subsystem is opt-in (subsystems.tailscale). Its absence is a
    # valid configuration, not a failure — mirror fetch_app-argocd.py's
    # sso_not_configured pattern so tailscale-less clusters pass.
    return {
        "ready": True,
        "status": "not_deployed",
        "summary": {
            "deployed": False,
            "operator_ready": False,
            "oauth_secret_ok": False,
            "oauth_synced": False,
            "secret_store_ready": False,
            "ingressclass_ok": False,
            "proxyclass_ready": False,
            "entrypoint_ingress_ok": False,
            "entrypoint_hostname_ok": False,
            "proxy_ready": False,
            "backend_http_ok": False,
            "tls_cert_issued": False,
        },
        "details": {},
        "errors": [],
        "note": "namespace 'tailscale' not present; the tailscale subsystem is not deployed here.",
    }


def fetch_tailscale() -> dict:
    # The generic workload check (fetch_k3s-apps.py) only sees replica counts.
    # Tailscale can be "all pods Running" yet unreachable: the OAuth secret never
    # synced, the ProxyClass wedged the Ingress reconcile so no device exists, or
    # the MagicDNS hostname was never assigned. This probe asserts the full chain
    # operator -> OAuth secret -> ProxyClass -> entrypoint Ingress -> proxy
    # StatefulSet -> Traefik tsnet backend is actually wired.
    errors: list = []

    ns_payload = get_resources("namespace")
    if "error" in ns_payload:
        return {
            "ready": False,
            "status": "unknown",
            "summary": {},
            "details": {},
            "errors": [{"resource": "namespace", "error": ns_payload["error"]}],
            "note": "could not list namespaces to determine whether tailscale is deployed.",
        }
    namespaces = {obj.get("metadata", {}).get("name") for obj in ns_payload.get("items", [])}
    if NS not in namespaces:
        return _not_deployed()

    operator = _check_operator(errors)
    oauth_secret = _check_oauth_secret(errors)
    oauth_es = _check_oauth_external_secret(errors)
    secret_store = _check_secret_store(errors)
    ingressclass = _check_ingressclass(errors)
    proxyclasses, proxyclass_ready = _check_proxyclasses(errors)
    entrypoint = _check_entrypoint_ingress(errors)
    backend_http = _check_backend_http(entrypoint, errors)
    proxies, proxy_ready = _check_proxy_statefulsets(errors)
    tls_cert = _check_tls_cert(entrypoint, errors)

    summary = {
        "deployed": True,
        "operator_ready": operator["ready"],
        "oauth_secret_ok": oauth_secret["ok"],
        "oauth_synced": oauth_es["synced"],
        "secret_store_ready": secret_store["ready"],
        "ingressclass_ok": ingressclass["ok"],
        "proxyclass_ready": proxyclass_ready,
        "entrypoint_ingress_ok": entrypoint["found"] and entrypoint["class_ok"],
        "entrypoint_hostname_ok": entrypoint["hostname_ok"],
        "proxy_ready": proxy_ready,
        "backend_http_ok": backend_http["ok"],
    }
    ready = all(summary.values())
    # Reported but excluded from `ready`: Tailscale issues the LE cert lazily
    # (first TLS connection), so a fresh cluster no client has hit yet has no
    # cert and that is not a fault. The answer sheet grades this as $warn —
    # a rate-limited / failing issuance shows YELLOW with the ACME error in
    # details.tls_cert.message instead of an all-green false positive.
    summary["tls_cert_issued"] = tls_cert["issued"]

    return {
        "ready": ready,
        "status": "ok" if ready else "degraded",
        "summary": summary,
        "details": {
            "operator": operator,
            "oauth_secret": oauth_secret,
            "oauth_external_secret": oauth_es,
            "secret_store": secret_store,
            "ingress_class": ingressclass,
            "proxy_classes": proxyclasses,
            "entrypoint_ingress": entrypoint,
            "backend_http": backend_http,
            "proxy_statefulsets": proxies,
            "tls_cert": tls_cert,
        },
        "errors": errors,
        "note": (
            "Asserts the tailnet entry point is wired end to end: operator rolled "
            "out, OAuth client synced from Parameter Store (non-empty), tailscale "
            "IngressClass + Ready ProxyClass present, tailnet-entrypoint Ingress "
            "carries a *.ts.net MagicDNS hostname, the proxy StatefulSet is ready, "
            "and Traefik's plaintext tsnet entrypoint answers HTTP. tls_cert_issued "
            "flags whether the device's Let's Encrypt cert exists in the proxy state "
            "Secret (issued lazily; absence => TLS to the tailnet URL hangs, see "
            "details.tls_cert.message). The tailnet-side leg (client -> device) is "
            "only verifiable from a machine on the tailnet."
        ),
    }


if __name__ == "__main__":
    output = fetch_tailscale()
    emit(output)
    sys.exit(0 if output["ready"] else 1)
