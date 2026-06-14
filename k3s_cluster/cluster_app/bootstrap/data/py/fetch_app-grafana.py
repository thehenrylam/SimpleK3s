#!/usr/bin/env python3

# Builtin Modules
import base64
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
get_resource = _utils.get_resource
http_get = _utils.http_get

NS = "monitoring"
SVC = "prometheus-grafana"
SSO_SECRET = "grafana-sso"
# Keys External Secrets pulls into grafana-sso and Grafana reads as env vars.
SSO_KEYS = ["oidc.cognito.domain", "oidc.cognito.client", "oidc.cognito.secret"]


def _check_health(svc: dict, errors: list) -> dict:
    # Grafana's /api/health returns {"database":"ok",...} when the server is up
    # and its DB is reachable — a stronger signal than "pod is Running" since a
    # Grafana that can't reach its DB still shows Ready.
    cip = svc.get("spec", {}).get("clusterIP")
    ports = svc.get("spec", {}).get("ports", [])
    port = ports[0].get("port") if ports else 80
    url = f"http://{cip}:{port}/api/health"

    resp = http_get(url)
    if resp["error"]:
        errors.append({"resource": "grafana /api/health", "error": resp["error"]})
        return {"reachable": False, "status": None, "database_ok": False, "ok": False, "url": url}

    database_ok = False
    try:
        database_ok = json.loads(resp["body"]).get("database") == "ok"
    except (json.JSONDecodeError, AttributeError):
        database_ok = False
    ok = resp["status"] == 200 and database_ok
    return {
        "reachable": True,
        "status": resp["status"],
        "database_ok": database_ok,
        "ok": ok,
        "url": url,
    }


def _check_sso(errors: list) -> dict:
    # Grafana consumes grafana-sso via secretKeyRef env vars; if the secret is
    # missing the pod won't start (caught generically), but an empty value yields
    # a broken OAuth login that still looks healthy. Assert every key is populated.
    secret, err = get_resource("secret", NS, SSO_SECRET)
    if err or not secret:
        # Secret absent => SSO not configured here; don't fail on it.
        return {"configured": False, "keys_ok": False, "empty_keys": []}
    data = secret.get("data", {})
    empty = []
    for key in SSO_KEYS:
        raw = data.get(key)
        try:
            value = base64.b64decode(raw).decode() if raw else ""
        except (ValueError, UnicodeDecodeError):
            value = ""
        if not value:
            empty.append(key)
    return {"configured": True, "keys_ok": not empty, "empty_keys": empty}


def fetch_grafana() -> dict:
    errors: list = []
    svc, err = get_resource("svc", NS, SVC)
    if err or not svc:
        return {
            "ready": True,
            "status": "not_deployed",
            "summary": {
                "health_ok": False,
                "sso_configured": False,
                "sso_keys_ok": False,
            },
            "details": {},
            "errors": errors,
            "note": f"Service {SVC} not present; Grafana is not deployed here.",
        }

    health = _check_health(svc, errors)
    sso = _check_sso(errors)
    # Fail only when SSO is configured but a key is empty; non-SSO clusters pass on health.
    ready = health["ok"] and (not sso["configured"] or sso["keys_ok"])

    return {
        "ready": ready,
        "status": "ok" if ready else "degraded",
        "summary": {
            "health_ok": health["ok"],
            "sso_configured": sso["configured"],
            "sso_keys_ok": sso["keys_ok"],
        },
        "details": {"health": health, "sso": sso},
        "errors": errors,
        "note": (
            "Asserts Grafana is actually serving (/api/health database=ok) and, when "
            "OAuth/SSO is configured, that the grafana-sso secret keys are populated."
        ),
    }


if __name__ == "__main__":
    output = fetch_grafana()
    print(json.dumps(output, indent=4))
    sys.exit(0 if output["ready"] else 1)
