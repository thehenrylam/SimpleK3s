"""List the Tailscale devices this deployment manages.

Read-only utility Lambda (uses the dedicated read-only OAuth client, so its token
cannot mutate anything). Invoke ad-hoc (`aws lambda invoke`) or from a
data.aws_lambda_invocation. Returns devices carrying the managed tags (default
tag:k8s / tag:k8s-operator), optionally narrowed to a hostname prefix.
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
DEFAULT_TAGS = ["tag:k8s", "tag:k8s-operator"]


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


def _summarize(device):
    return {
        "id": device.get("id"),
        "name": device.get("name"),
        "hostname": device.get("hostname"),
        "tags": device.get("tags", []),
        "addresses": device.get("addresses", []),
        "lastSeen": device.get("lastSeen"),
        "online": device.get("online"),
    }


def handler(event, _context):
    tags = event.get("tags") or DEFAULT_TAGS
    prefix = event.get("hostname_prefix")  # optional narrowing

    client_id, client_secret = _get_oauth_client()
    token = _get_token(client_id, client_secret)
    devices = _http("GET", f"{TS_API}/tailnet/-/devices", token=token).get("devices", [])

    result = []
    for device in devices:
        if not (set(device.get("tags", [])) & set(tags)):
            continue
        if prefix is not None:
            short_name = device.get("name", "").split(".")[0]
            if not (short_name == prefix or short_name.startswith(f"{prefix}-")):
                continue
        result.append(_summarize(device))

    logger.info("Listed %d of %d device(s)", len(result), len(devices))
    return {"count": len(result), "devices": result}
