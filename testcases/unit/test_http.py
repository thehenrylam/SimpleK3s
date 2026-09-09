"""In-cluster HTTP probing.

Nothing here may raise: every failure mode has to come back as a value, because
these feed facts and a transport error is itself the reading.
"""

import urllib.error

from sk3s_verify import http


class FakeResponse:
    def __init__(self, status, body):
        self.status = status
        self._body = body.encode()

    def read(self, size):
        return self._body[:size]


def test_a_successful_get_returns_status_and_body(monkeypatch):
    monkeypatch.setattr(
        http.urllib.request,
        "build_opener",
        lambda *h: type("O", (), {"open": lambda s, u, timeout: FakeResponse(200, "hello")})(),
    )
    assert http.get("http://x") == {"status": 200, "body": "hello", "error": None}


def test_an_http_error_status_is_an_answer_not_a_transport_failure(monkeypatch):
    def raiser(self, url, timeout):
        raise urllib.error.HTTPError(url, 404, "Not Found", {}, None)

    monkeypatch.setattr(
        http.urllib.request, "build_opener", lambda *h: type("O", (), {"open": raiser})()
    )
    result = http.get("http://x")
    assert result["status"] == 404
    assert result["error"] is None


def test_a_refused_connection_is_reported_never_raised(monkeypatch):
    def raiser(self, url, timeout):
        raise ConnectionRefusedError("refused")

    monkeypatch.setattr(
        http.urllib.request, "build_opener", lambda *h: type("O", (), {"open": raiser})()
    )
    result = http.get("http://x")
    assert result["status"] is None
    assert "refused" in result["error"]


def test_the_body_is_bounded(monkeypatch):
    monkeypatch.setattr(
        http.urllib.request,
        "build_opener",
        lambda *h: type("O", (), {"open": lambda s, u, timeout: FakeResponse(200, "x" * 10000)})(),
    )
    assert len(http.get("http://x", max_bytes=16)["body"]) == 16


def test_json_body_parses_a_json_response():
    assert http.json_body({"body": '{"database":"ok"}'}) == {"database": "ok"}


def test_json_body_is_none_for_html():
    assert http.json_body({"body": "<html>nope</html>"}) is None


# ─── Service resolution ──────────────────────────────────────────────────────


def service(cluster_ip="10.0.0.1", ports=(80,)):
    return {"spec": {"clusterIP": cluster_ip, "ports": [{"port": p} for p in ports]}}


def test_endpoint_resolves_the_first_port_by_default(monkeypatch):
    monkeypatch.setattr(http.kube, "run_json", lambda *a, **k: service(ports=(80, 443)))
    assert http.endpoint("ns", "svc") == ("10.0.0.1", 80)


def test_endpoint_honours_a_requested_port(monkeypatch):
    monkeypatch.setattr(http.kube, "run_json", lambda *a, **k: service(ports=(80, 9090)))
    assert http.endpoint("ns", "svc", port=9090) == ("10.0.0.1", 9090)


def test_endpoint_refuses_a_port_the_service_does_not_expose(monkeypatch):
    monkeypatch.setattr(http.kube, "run_json", lambda *a, **k: service(ports=(80,)))
    assert http.endpoint("ns", "svc", port=9090) is None


def test_a_headless_service_is_unusable_not_a_url_of_none(monkeypatch):
    """prometheus-operated is headless; 'http://None:9090' would fail confusingly."""
    monkeypatch.setattr(http.kube, "run_json", lambda *a, **k: service(cluster_ip="None"))
    assert http.endpoint("ns", "svc") is None


def test_an_unreadable_service_resolves_to_none(monkeypatch):
    def boom(*a, **k):
        raise http.kube.Unavailable("nope")

    monkeypatch.setattr(http.kube, "run_json", boom)
    assert http.endpoint("ns", "svc") is None


def test_probe_reports_an_unresolvable_service_without_raising(monkeypatch):
    monkeypatch.setattr(http, "endpoint", lambda *a, **k: None)
    result = http.probe("ns", "svc", "/health")
    assert result["url"] is None
    assert "could not resolve service ns/svc" in result["error"]


def test_probe_builds_the_url_from_the_resolved_endpoint(monkeypatch):
    monkeypatch.setattr(http, "endpoint", lambda *a, **k: ("10.1.2.3", 9090))
    monkeypatch.setattr(http, "get", lambda url, **k: {"status": 200, "body": "", "error": None})
    assert http.probe("ns", "svc", "/-/ready")["url"] == "http://10.1.2.3:9090/-/ready"
