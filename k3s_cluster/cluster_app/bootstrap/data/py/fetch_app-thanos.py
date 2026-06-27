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
get_resources = _utils.get_resources
http_get = _utils.http_get

NS = "monitoring"
# The raw-manifest Deployments that make up the Thanos long-term-storage tier.
THANOS_DEPLOYMENTS = ("thanos-query", "thanos-store", "thanos-compactor")


def _collect_deployments(errors: list) -> dict:
    # Grade each Thanos Deployment by readyReplicas == desired. "Pod Running" is
    # not enough; a Deployment with 0 ready replicas is still down.
    payload = get_resources("deploy")
    if "error" in payload:
        errors.append({"resource": "deploy", "error": payload["error"]})
        return {}
    found = {}
    for obj in payload.get("items", []):
        meta = obj.get("metadata", {})
        if meta.get("namespace") != NS:
            continue
        name = meta.get("name", "")
        if name not in THANOS_DEPLOYMENTS:
            continue
        desired = obj.get("spec", {}).get("replicas", 0)
        ready = obj.get("status", {}).get("readyReplicas", 0)
        found[name] = {
            "desired": desired,
            "ready": ready,
            "available": desired > 0 and ready == desired,
        }
    return found


def _find_query_service(errors: list) -> dict:
    # The Querier's HTTP API (:9090) is what Grafana points at. Match the
    # thanos-query Service by name and require a real clusterIP.
    payload = get_resources("svc")
    if "error" in payload:
        errors.append({"resource": "svc", "error": payload["error"]})
        return {}
    for obj in payload.get("items", []):
        meta = obj.get("metadata", {})
        if meta.get("namespace") != NS or meta.get("name") != "thanos-query":
            continue
        cip = obj.get("spec", {}).get("clusterIP")
        if not cip or cip == "None":
            continue
        return {"name": "thanos-query", "clusterIP": cip, "port": 9090}
    return {}


def _check_endpoint(svc: dict, suffix: str, errors: list) -> dict:
    url = f"http://{svc['clusterIP']}:{svc['port']}{suffix}"
    resp = http_get(url)
    if resp["error"]:
        errors.append({"resource": f"thanos-query {suffix}", "error": resp["error"]})
        return {"status": None, "ok": False, "url": url}
    return {"status": resp["status"], "ok": resp["status"] == 200, "url": url}


def _check_stores(svc: dict, errors: list) -> dict:
    # /api/v1/stores groups connected StoreAPIs by component (sidecar/store/...).
    # A healthy setup must list the Prometheus *sidecar* — its absence is exactly
    # the sidecar-discovery misconfig that leaves Grafana with no recent data even
    # though every pod is "Running". Read more than the default 512 bytes so the
    # JSON parses.
    url = f"http://{svc['clusterIP']}:{svc['port']}/api/v1/stores"
    resp = http_get(url, max_bytes=65536)
    blank = {"reachable": False, "by_component": {}, "total": 0, "sidecar_connected": False}
    if resp["error"]:
        errors.append({"resource": "thanos-query /api/v1/stores", "error": resp["error"]})
        return blank
    try:
        data = json.loads(resp["body"]).get("data", {})
    except (ValueError, AttributeError) as exc:
        errors.append({"resource": "thanos-query /api/v1/stores", "error": f"parse: {exc!r}"})
        return {**blank, "reachable": True}
    by_component = {
        comp: len(entries) for comp, entries in data.items() if isinstance(entries, list)
    }
    return {
        "reachable": True,
        "by_component": by_component,
        "total": sum(by_component.values()),
        "sidecar_connected": by_component.get("sidecar", 0) >= 1,
    }


def fetch_thanos() -> dict:
    errors: list = []
    deploys = _collect_deployments(errors)

    if not deploys:
        # No Thanos Deployments => the monitoring stack (and Thanos) isn't here.
        return {
            "ready": True,
            "status": "not_deployed",
            "summary": {
                "query_ready": False,
                "store_ready": False,
                "compactor_ready": False,
                "query_healthy_ok": False,
                "query_ready_ok": False,
                "sidecar_connected": False,
                "stores_total": 0,
            },
            "details": {},
            "errors": errors,
            "note": "No Thanos Deployments present; the monitoring stack is not deployed here.",
        }

    query_ready = deploys.get("thanos-query", {}).get("available", False)
    store_ready = deploys.get("thanos-store", {}).get("available", False)
    compactor_ready = deploys.get("thanos-compactor", {}).get("available", False)

    svc = _find_query_service(errors)
    if svc:
        healthy = _check_endpoint(svc, "/-/healthy", errors)
        readyz = _check_endpoint(svc, "/-/ready", errors)
        stores = _check_stores(svc, errors)
    else:
        errors.append({"resource": "svc/thanos-query :9090", "error": "no query Service found"})
        healthy = {"status": None, "ok": False, "url": None}
        readyz = {"status": None, "ok": False, "url": None}
        stores = {"reachable": False, "by_component": {}, "total": 0, "sidecar_connected": False}

    ready = (
        query_ready
        and store_ready
        and compactor_ready
        and healthy["ok"]
        and readyz["ok"]
        and stores["sidecar_connected"]
    )

    return {
        "ready": ready,
        "status": "ok" if ready else "degraded",
        "summary": {
            "query_ready": query_ready,
            "store_ready": store_ready,
            "compactor_ready": compactor_ready,
            "query_healthy_ok": healthy["ok"],
            "query_ready_ok": readyz["ok"],
            "sidecar_connected": stores["sidecar_connected"],
            "stores_total": stores["total"],
        },
        "details": {
            "deployments": deploys,
            "service": svc,
            "healthy": healthy,
            "ready": readyz,
            "stores": stores,
        },
        "errors": errors,
        "note": (
            "Asserts the thanos-query/store/compactor Deployments are Available, the Querier "
            "answers /-/healthy and /-/ready (200), and the Prometheus sidecar StoreAPI is "
            "connected to the Querier (catches the sidecar-discovery misconfig that hides recent "
            "metrics from Grafana even when every pod is Running)."
        ),
    }


if __name__ == "__main__":
    output = fetch_thanos()
    emit(output)
    sys.exit(0 if output["ready"] else 1)
