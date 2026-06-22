#!/usr/bin/env python3

# Builtin Modules
import base64
import importlib.util
import os
import re
import sys

_dir = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "fetch_UTILITIES", os.path.join(_dir, "fetch_UTILITIES.py")
)
_utils = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_utils)
emit = _utils.emit
get_resource = _utils.get_resource
http_get = _utils.http_get

NS = "argocd"
# HTTP redirect codes — a healthy /auth/login bounces the browser to the IdP.
_REDIRECT_CODES = {301, 302, 303, 307, 308}


def _get_oidc_issuer_token(errors: list):
    # Read argocd-cm's oidc.config and pull the raw `issuer:` token. Returns None
    # when SSO isn't configured at all (argocd-cm or oidc.config absent) so that
    # non-SSO / argocd-less clusters are treated as a pass rather than a failure.
    cm, err = get_resource("cm", NS, "argocd-cm")
    if err or not cm:
        return None
    oidc = cm.get("data", {}).get("oidc.config")
    if not oidc:
        return None
    for line in oidc.splitlines():
        m = re.match(r"\s*issuer:\s*(\S+)", line)
        if m:
            return m.group(1)
    return ""  # oidc.config present but malformed (no issuer line)


def _resolve_issuer(token: str, errors: list) -> tuple:
    # Confirm ArgoCD can actually resolve the issuer. A `$<secret>:<key>` (or the
    # unqualified `$key` against argocd-secret) only resolves when the secret
    # exists, the key is populated, AND the secret carries
    # app.kubernetes.io/part-of: argocd. A missing label or empty value silently
    # yields an empty issuer — the original #95 "unsupported protocol scheme" cause.
    if not token:
        return False, {"issuer_ref": token, "reason": "no issuer in oidc.config"}
    if not token.startswith("$"):
        return True, {"issuer_ref": token, "reason": "literal issuer (no secret ref)"}

    ref = token[1:]
    if ":" in ref:
        secret_name, key = ref.split(":", 1)
    else:
        secret_name, key = "argocd-secret", ref

    secret, err = get_resource("secret", NS, secret_name)
    if err or not secret:
        errors.append({"resource": f"secret/{secret_name}", "error": err or "not found"})
        return False, {
            "issuer_ref": token,
            "secret": secret_name,
            "key": key,
            "reason": "secret not found",
        }

    raw = secret.get("data", {}).get(key)
    try:
        value = base64.b64decode(raw).decode() if raw else ""
    except (ValueError, UnicodeDecodeError):
        value = ""
    labels = secret.get("metadata", {}).get("labels", {})
    part_of = labels.get("app.kubernetes.io/part-of") == "argocd"

    return (bool(value) and part_of), {
        "issuer_ref": token,
        "secret": secret_name,
        "key": key,
        "value_present": bool(value),
        "part_of_argocd_label": part_of,
    }


def _check_login_route(errors: list) -> dict:
    # argocd-server registers the OIDC /auth/login + /auth/callback HTTP routes
    # ONCE at startup, and only when SSO resolved as configured then. On a fresh
    # deploy it can boot before the OIDC secret is synced, leaving those routes
    # unregistered: /auth/login then 404s and the SSO button dead-ends on a blank
    # page (#95). We hit the route via the in-cluster Service ClusterIP (reachable
    # from a K3s node host) and assert a 3xx redirect to the IdP.
    svc, err = get_resource("svc", NS, "argocd-server")
    if err or not svc:
        errors.append({"resource": "svc/argocd-server", "error": err or "not found"})
        return {"reachable": False, "status": None, "ok": False, "url": None}

    cip = svc.get("spec", {}).get("clusterIP")
    ports = svc.get("spec", {}).get("ports", [])
    port = ports[0].get("port") if ports else 80

    params, _ = get_resource("cm", NS, "argocd-cmd-params-cm")
    rootpath = (params or {}).get("data", {}).get("server.rootpath", "") if params else ""

    url = f"http://{cip}:{port}{rootpath}/auth/login"
    resp = http_get(url, follow_redirects=False)
    if resp["error"]:
        errors.append({"resource": "argocd-server /auth/login", "error": resp["error"]})
        return {"reachable": False, "status": None, "ok": False, "url": url}

    status = resp["status"]
    return {"reachable": True, "status": status, "ok": status in _REDIRECT_CODES, "url": url}


def fetch_argocd() -> dict:
    # ArgoCD SSO has two independent failure layers the generic workload check
    # can't see: (1) the OIDC secret never syncs, so the issuer resolves empty;
    # (2) argocd-server boots before the secret exists, so the /auth/login route
    # is never registered. This probe asserts both are actually wired.
    errors: list = []
    token = _get_oidc_issuer_token(errors)

    if token is None:
        return {
            "ready": True,
            "status": "sso_not_configured",
            "summary": {
                "sso_configured": False,
                "issuer_resolved": False,
                "login_route_ok": False,
                "login_route_status": None,
            },
            "details": {},
            "errors": errors,
            "note": "argocd-cm/oidc.config not present; ArgoCD SSO is not configured here.",
        }

    issuer_resolved, issuer_detail = _resolve_issuer(token, errors)
    route = _check_login_route(errors)
    ready = issuer_resolved and route["ok"]

    return {
        "ready": ready,
        "status": "ok" if ready else "degraded",
        "summary": {
            "sso_configured": True,
            "issuer_resolved": issuer_resolved,
            "login_route_ok": route["ok"],
            "login_route_status": route["status"],
        },
        "details": {"issuer": issuer_detail, "login_route": route},
        "errors": errors,
        "note": (
            "Asserts ArgoCD SSO is wired end to end: the oidc.config issuer resolves "
            "to a populated, part-of:argocd secret, and argocd-server has registered "
            "the /auth/login route (3xx). A 404 is the #95 white-screen failure."
        ),
    }


if __name__ == "__main__":
    output = fetch_argocd()
    emit(output)
    sys.exit(0 if output["ready"] else 1)
