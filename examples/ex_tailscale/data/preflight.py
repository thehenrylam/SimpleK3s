"""Preflight validation of the tailnet before a cluster deploy.

Read-only Lambda (dedicated read-only OAuth client). Dispatches on event["check"]:
  - "tags": the tailnet policy must define owners for the required tags
    (tag:k8s, tag:k8s-operator) — without them the operator can't register.
  - "dns":  MagicDNS must be enabled (required for the tailnet host + HTTPS certs).

Returns {"ok": bool, "check": str, "checked": bool, "findings": [...]}.
FAIL-OPEN: on any Tailscale API/network error it returns ok=true, checked=false,
so a transient hiccup never blocks an otherwise-fine apply. ok=false is returned
only when a real misconfiguration is positively determined.
"""

import json
import logging
import os
import urllib.parse
import urllib.request

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

TS_API = "https://api.tailscale.com/api/v2"
OAUTH_TOKEN_URL = f"{TS_API}/oauth/token"
HTTP_TIMEOUT = 15
REQUIRED_TAGS = ["tag:k8s", "tag:k8s-operator"]


def _http(method, url, *, token=None, data=None, accept=None):
    """Minimal JSON HTTP helper (stdlib only — no packaged deps)."""
    headers = {}
    body = None
    if data is not None:
        body = urllib.parse.urlencode(data).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    if accept is not None:
        headers["Accept"] = accept
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:  # noqa: S310
        payload = resp.read()
    return json.loads(payload) if payload else {}


def _get_oauth_client():
    param = os.environ["TS_OAUTH_SSM_PARAM"]
    ssm = boto3.client("ssm")
    raw = ssm.get_parameter(Name=param, WithDecryption=True)["Parameter"]["Value"]
    creds = json.loads(raw)
    return creds["client_id"], creds["client_secret"]


def _get_token(client_id, client_secret):
    resp = _http(
        "POST",
        OAUTH_TOKEN_URL,
        data={"client_id": client_id, "client_secret": client_secret},
    )
    return resp["access_token"]


def _check_tags(token, required):
    """Assert the tailnet policy defines owners for every required tag."""
    acl = _http(
        "GET", f"{TS_API}/tailnet/-/acl", token=token, accept="application/json"
    )
    tag_owners = acl.get("tagOwners", {})
    missing = [t for t in required if t not in tag_owners]
    findings = [f"tag owner not defined in tailnet policy: {t}" for t in missing]
    return (len(missing) == 0), findings


def _check_dns(token):
    """Assert MagicDNS is enabled (required for the tailnet host + HTTPS certs)."""
    prefs = _http("GET", f"{TS_API}/tailnet/-/dns/preferences", token=token)
    magic_dns = bool(prefs.get("magicDNS"))
    findings = [] if magic_dns else ["MagicDNS is disabled for the tailnet"]
    return magic_dns, findings


def handler(event, _context):
    check = event.get("check", "tags")
    required = event.get("required_tags") or REQUIRED_TAGS

    try:
        client_id, client_secret = _get_oauth_client()
        token = _get_token(client_id, client_secret)
        if check == "tags":
            ok, findings = _check_tags(token, required)
        elif check == "dns":
            ok, findings = _check_dns(token)
        else:
            return {
                "ok": False,
                "check": check,
                "checked": True,
                "findings": [f"unknown check: {check}"],
            }
    except Exception as exc:  # noqa: BLE001 — FAIL-OPEN so a hiccup can't block apply
        logger.warning("preflight %s could not run (failing open): %s", check, exc)
        return {"ok": True, "check": check, "checked": False, "error": str(exc)}

    logger.info("preflight %s ok=%s findings=%s", check, ok, findings)
    return {"ok": ok, "check": check, "checked": True, "findings": findings}
