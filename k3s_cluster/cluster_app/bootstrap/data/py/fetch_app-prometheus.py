#!/usr/bin/env python3

# Builtin Modules
import importlib.util
import os
import sys

_dir = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "fetch_UTILITIES", os.path.join(_dir, "fetch_UTILITIES.py")
)
_utils = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_utils)
emit = _utils.emit
get_resources = _utils.get_resources
http_get = _utils.http_get

NS = "monitoring"
# The Prometheus CR reports health via Available + Reconciled (not a Ready condition).
_REQUIRED_CONDITIONS = ("Available", "Reconciled")


def _collect_crs(errors: list) -> tuple:
    # Evaluate every Prometheus CR by its operator-managed conditions. A CR that
    # is Available+Reconciled=True means the operator has rolled out a healthy
    # StatefulSet; a degraded condition is the gap "pod is Running" can't see.
    payload = get_resources("prometheus")
    if "error" in payload:
        errors.append({"resource": "prometheus", "error": payload["error"]})
        return [], None
    crs = []
    route_prefix = None
    for obj in payload.get("items", []):
        spec = obj.get("spec", {})
        if route_prefix is None:
            route_prefix = spec.get("routePrefix") or ""
        status_conds = obj.get("status", {}).get("conditions", [])
        conds = {c.get("type"): c.get("status") for c in status_conds}
        cr_ready = all(conds.get(t) == "True" for t in _REQUIRED_CONDITIONS)
        crs.append(
            {
                "name": obj.get("metadata", {}).get("name", ""),
                "ready": cr_ready,
                "conditions": conds,
            }
        )
    return crs, (route_prefix or "")


def _find_query_service(errors: list) -> dict:
    # The operator's `prometheus-operated` Service is headless (no clusterIP), so
    # we target the stack's regular :9090 Service. Match by port rather than a
    # hardcoded name to survive release-name differences.
    payload = get_resources("svc")
    if "error" in payload:
        errors.append({"resource": "svc", "error": payload["error"]})
        return {}
    for obj in payload.get("items", []):
        meta = obj.get("metadata", {})
        spec = obj.get("spec", {})
        name = meta.get("name", "")
        if meta.get("namespace") != NS or "prometheus" not in name:
            continue
        if "operated" in name or "operator" in name or "node-exporter" in name:
            continue
        cip = spec.get("clusterIP")
        if not cip or cip == "None":
            continue
        if any(p.get("port") == 9090 for p in spec.get("ports", [])):
            return {"name": name, "clusterIP": cip, "port": 9090}
    return {}


def _check_endpoint(svc: dict, route_prefix: str, suffix: str, errors: list) -> dict:
    url = f"http://{svc['clusterIP']}:{svc['port']}{route_prefix}{suffix}"
    resp = http_get(url)
    if resp["error"]:
        errors.append({"resource": f"prometheus {suffix}", "error": resp["error"]})
        return {"status": None, "ok": False, "url": url}
    return {"status": resp["status"], "ok": resp["status"] == 200, "url": url}


def fetch_prometheus() -> dict:
    errors: list = []
    crs, route_prefix = _collect_crs(errors)

    if route_prefix is None:
        # No Prometheus CRD/CR present => monitoring stack not deployed here.
        return {
            "ready": True,
            "status": "not_deployed",
            "summary": {
                "prometheus_crs_total": 0,
                "prometheus_crs_ready": 0,
                "healthy_ok": False,
                "ready_ok": False,
            },
            "details": {},
            "errors": errors,
            "note": "No Prometheus CR present; the monitoring stack is not deployed here.",
        }

    svc = _find_query_service(errors)
    if svc:
        healthy = _check_endpoint(svc, route_prefix, "/-/healthy", errors)
        readyz = _check_endpoint(svc, route_prefix, "/-/ready", errors)
    else:
        errors.append({"resource": "svc/prometheus :9090", "error": "no query Service found"})
        healthy = {"status": None, "ok": False, "url": None}
        readyz = {"status": None, "ok": False, "url": None}

    crs_ready = sum(1 for c in crs if c["ready"])
    all_crs_ready = bool(crs) and crs_ready == len(crs)
    ready = all_crs_ready and healthy["ok"] and readyz["ok"]

    return {
        "ready": ready,
        "status": "ok" if ready else "degraded",
        "summary": {
            "prometheus_crs_total": len(crs),
            "prometheus_crs_ready": crs_ready,
            "healthy_ok": healthy["ok"],
            "ready_ok": readyz["ok"],
        },
        "details": {
            "route_prefix": route_prefix,
            "service": svc,
            "crs": crs,
            "healthy": healthy,
            "ready": readyz,
        },
        "errors": errors,
        "note": (
            "Asserts the Prometheus CR is Available+Reconciled and the server answers "
            "its routePrefix /-/healthy and /-/ready endpoints (200) from in-cluster."
        ),
    }


if __name__ == "__main__":
    output = fetch_prometheus()
    emit(output)
    sys.exit(0 if output["ready"] else 1)
