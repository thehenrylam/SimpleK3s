"""Delete this cluster's Tailscale devices when the cluster is destroyed.

Invoked by Terraform (aws_lambda_invocation, lifecycle_scope = "CRUD") from the
ex_basic cluster root. Only the destroy action does work; create/update are
no-ops (destroy-only cleanup). Reuses the operator OAuth client (read from SSM)
to call the Tailscale API and remove devices whose short name matches this
cluster's hostname prefix AND whose tags intersect the cluster tags, so it can
only ever match the cluster that is being torn down.
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


def _http(method, url, *, token=None, data=None):
    """Minimal JSON HTTP helper (stdlib only — no packaged deps)."""
    headers = {}
    body = None
    if data is not None:
        body = urllib.parse.urlencode(data).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:  # noqa: S310
        payload = resp.read()
    return json.loads(payload) if payload else {}


def _get_oauth_client():
    """Read { client_id, client_secret } from the operator OAuth SSM param."""
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


def _matches(device, prefix, tags):
    """True when the device belongs to this cluster (name prefix + shared tag)."""
    short_name = device.get("name", "").split(".")[0]
    name_match = short_name == prefix or short_name.startswith(f"{prefix}-")
    tag_match = bool(set(device.get("tags", [])) & set(tags))
    return name_match and tag_match


def handler(event, _context):
    action = event.get("tf", {}).get("action")
    if action != "delete":
        logger.info("action=%s is not a delete; skipping cleanup", action)
        return {"skipped": action}

    prefix = event["hostname_prefix"]
    tags = event.get("tags", [])
    logger.info("Cleaning up devices for prefix=%s tags=%s", prefix, tags)

    client_id, client_secret = _get_oauth_client()
    token = _get_token(client_id, client_secret)

    devices = _http("GET", f"{TS_API}/tailnet/-/devices", token=token).get("devices", [])
    targets = [d for d in devices if _matches(d, prefix, tags)]
    logger.info("Matched %d of %d device(s)", len(targets), len(devices))

    deleted, failed = [], []
    for device in targets:
        name = device.get("name", device["id"])
        try:
            _http("DELETE", f"{TS_API}/device/{device['id']}", token=token)
            logger.info("Deleted device %s (%s)", name, device["id"])
            deleted.append(name)
        except Exception as exc:  # noqa: BLE001 — never wedge a destroy on one device
            logger.warning("Failed to delete %s (%s): %s", name, device["id"], exc)
            failed.append(name)

    return {"deleted": deleted, "failed": failed, "matched": len(targets)}
