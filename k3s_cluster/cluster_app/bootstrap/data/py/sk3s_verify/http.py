"""HTTP probing from inside the cluster.

WHY. kubectl can tell you a Deployment is Ready. It cannot tell you the process
behind it answers — Grafana with an unreachable database reports Ready and
serves a broken UI, and argocd-server that booted before its OIDC secret serves
a login route that 404s. Those signals only exist over the wire.

These feed FACTS, never verdicts. A probe that cannot connect records that it
could not connect, with the reason; deciding whether that is acceptable belongs
to whatever consumes the report. So nothing here raises — every failure mode is
a value the caller can read.
"""

import json
import urllib.error
import urllib.request

from . import kube

DEFAULT_TIMEOUT = 10

# Enough for a JSON status payload (Thanos /api/v1/stores is the largest we
# read) without pulling a whole HTML page into the report.
DEFAULT_MAX_BYTES = 4096


def get(url, timeout=DEFAULT_TIMEOUT, follow_redirects=True, max_bytes=DEFAULT_MAX_BYTES):
    """GET a URL. Returns {"status", "body", "error"} — never raises.

    follow_redirects=False keeps the 3xx so a caller can assert on the redirect
    itself, which is the only way to tell a registered OIDC login route from a
    single-page-app fallback that returns 200 for everything.
    """
    handlers = []
    if not follow_redirects:

        class _NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None

        handlers.append(_NoRedirect())

    opener = urllib.request.build_opener(*handlers)
    try:
        response = opener.open(url, timeout=timeout)
        body = response.read(max_bytes).decode("utf-8", "replace")
        return {"status": response.status, "body": body, "error": None}
    except urllib.error.HTTPError as exc:
        # A 4xx/5xx is an answer, not a transport failure.
        return {"status": exc.code, "body": "", "error": None}
    except Exception as exc:  # noqa: BLE001 - any transport failure is the signal
        return {"status": None, "body": "", "error": repr(exc)}


def json_body(response):
    """Parse a probe response's body, or None if it is not JSON."""
    try:
        return json.loads(response["body"])
    except (ValueError, TypeError):
        return None


def endpoint(namespace, name, port=None):
    """Resolve a Service to (clusterIP, port), or None if it cannot be used.

    A headless Service has no clusterIP — the operator's `prometheus-operated`
    is one — so it is reported as unusable rather than producing a URL of
    "http://None:9090" that fails confusingly later.
    """
    try:
        service = kube.run_json(["-n", namespace, "get", "svc", name])
    except kube.Unavailable:
        return None
    spec = service.get("spec", {})
    cluster_ip = spec.get("clusterIP")
    if not cluster_ip or cluster_ip == "None":
        return None
    ports = spec.get("ports") or []
    if port is not None:
        if not any(p.get("port") == port for p in ports):
            return None
        return cluster_ip, port
    if not ports:
        return None
    return cluster_ip, ports[0].get("port")


def probe(namespace, service, path, port=None, follow_redirects=True):
    """Resolve a Service and GET a path on it. Always returns a readable dict."""
    resolved = endpoint(namespace, service, port)
    if resolved is None:
        return {
            "url": None,
            "status": None,
            "body": "",
            "error": f"could not resolve service {namespace}/{service}",
        }
    cluster_ip, resolved_port = resolved
    url = f"http://{cluster_ip}:{resolved_port}{path}"
    return {"url": url, **get(url, follow_redirects=follow_redirects)}
