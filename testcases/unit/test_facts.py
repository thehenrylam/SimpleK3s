"""FULL-depth fact collection.

The one invariant that matters: a collector records READINGS, never verdicts. An
unreachable endpoint is a fact that says it was unreachable — not a failed check
— because grading lives outside this tool.
"""

import pytest
from sk3s_verify import kube, registry
from sk3s_verify.checks import facts


class Recorder:
    """Captures both channels so a test can assert a collector used neither."""

    def __init__(self):
        self.verdicts = []
        self.facts = {}

    def passed(self, message):
        self.verdicts.append(("passed", message))

    def failed(self, message, detail=None):
        self.verdicts.append(("failed", message))

    def skipped(self, message):
        self.verdicts.append(("skipped", message))

    def verdict(self, ok, message):
        (self.passed if ok else self.failed)(message)

    def fact(self, key, value):
        self.facts[key] = value


def stub_probe(monkeypatch, response):
    monkeypatch.setattr(facts.http, "probe", lambda *a, **k: dict(response))


def unavailable(*args, **kwargs):
    raise kube.Unavailable("connection refused")


# ─── The invariant ───────────────────────────────────────────────────────────

COLLECTORS = [
    facts.monitoring,
    facts.argocd,
    facts.tailscale,
    facts.traefik,
    facts.kyverno,
    facts.karpenter,
    facts.external_secrets,
    facts.longhorn,
    facts.storage,
    facts.nodes,
]


@pytest.mark.parametrize("collector", COLLECTORS)
def test_a_collector_never_records_a_verdict(monkeypatch, collector):
    monkeypatch.setattr(facts.kube, "run_json", lambda *a, **k: {"items": []})
    monkeypatch.setattr(
        facts.http,
        "probe",
        lambda *a, **k: {"url": "u", "status": 200, "body": "{}", "error": None},
    )
    rec = Recorder()
    collector(rec)
    assert rec.verdicts == []
    assert rec.facts


@pytest.mark.parametrize("collector", COLLECTORS)
def test_an_unreachable_cluster_is_recorded_as_a_fact_not_a_failure(monkeypatch, collector):
    """This is the whole point: full depth must not fail a run over a reading."""
    monkeypatch.setattr(facts.kube, "run_json", unavailable)
    monkeypatch.setattr(
        facts.http,
        "probe",
        lambda *a, **k: {"url": None, "status": None, "body": "", "error": "boom"},
    )
    rec = Recorder()
    collector(rec)
    assert rec.verdicts == []
    assert rec.facts


# ─── _listing ────────────────────────────────────────────────────────────────


def test_listing_reports_names_and_a_total(monkeypatch):
    payload = {
        "items": [
            {"metadata": {"name": "b", "namespace": "ns"}},
            {"metadata": {"name": "a", "namespace": "ns"}},
        ]
    }
    monkeypatch.setattr(facts.kube, "run_json", lambda *a, **k: payload)
    assert facts._listing("things") == {"total": 2, "names": ["ns/a", "ns/b"]}


def test_listing_reports_a_missing_crd_rather_than_an_empty_list(monkeypatch):
    """An absent CRD is a real answer; an empty list would read as 'none exist'."""
    monkeypatch.setattr(facts.kube, "run_json", unavailable)
    assert facts._listing("nodepools") == {"error": "connection refused"}


def test_listing_omits_the_namespace_for_cluster_scoped_kinds(monkeypatch):
    monkeypatch.setattr(
        facts.kube, "run_json", lambda *a, **k: {"items": [{"metadata": {"name": "x"}}]}
    )
    assert facts._listing("storageclasses")["names"] == ["x"]


# ─── Monitoring ──────────────────────────────────────────────────────────────


def test_prometheus_service_is_matched_by_port_not_by_name(monkeypatch):
    payload = {
        "items": [
            {"metadata": {"name": "prometheus-operated"}, "spec": {"clusterIP": "None"}},
            {
                "metadata": {"name": "release-with-any-prefix"},
                "spec": {"clusterIP": "10.0.0.1", "ports": [{"port": 9090}]},
            },
        ]
    }
    monkeypatch.setattr(facts.kube, "run_json", lambda *a, **k: payload)
    assert facts.prometheus_service() == "release-with-any-prefix"


def test_prometheus_service_skips_the_operator_and_headless_services(monkeypatch):
    payload = {
        "items": [
            {
                "metadata": {"name": "kube-prometheus-operator"},
                "spec": {"clusterIP": "10.0.0.2", "ports": [{"port": 9090}]},
            },
            {
                "metadata": {"name": "prometheus-operated"},
                "spec": {"clusterIP": "None", "ports": [{"port": 9090}]},
            },
        ]
    }
    monkeypatch.setattr(facts.kube, "run_json", lambda *a, **k: payload)
    assert facts.prometheus_service() is None


def test_grafana_fact_carries_the_database_verdict_without_grading_it(monkeypatch):
    stub_probe(
        monkeypatch,
        {
            "url": "http://x/api/health",
            "status": 200,
            "body": '{"database":"ok","version":"11"}',
            "error": None,
        },
    )
    rec = Recorder()
    facts.monitoring(rec)
    grafana = rec.facts["grafana"]
    assert grafana["status"] == 200
    assert grafana["database"] == "ok"
    assert rec.verdicts == []


def test_thanos_counts_stores_by_component(monkeypatch):
    body = '{"data":{"sidecar":[{"name":"a"}],"store":[{"name":"b"},{"name":"c"}]}}'
    stub_probe(monkeypatch, {"url": "http://x", "status": 200, "body": body, "error": None})
    monkeypatch.setattr(facts.kube, "run_json", lambda *a, **k: {"items": []})
    rec = Recorder()
    facts.monitoring(rec)
    stores = rec.facts["thanos"]["stores"]
    assert stores["by_component"] == {"sidecar": 1, "store": 2}
    assert stores["total"] == 3
    assert stores["sidecar_connected"] is True


def test_a_missing_sidecar_is_reported_not_graded(monkeypatch):
    stub_probe(
        monkeypatch,
        {
            "url": "http://x",
            "status": 200,
            "body": '{"data":{"store":[{"name":"b"}]}}',
            "error": None,
        },
    )
    monkeypatch.setattr(facts.kube, "run_json", lambda *a, **k: {"items": []})
    rec = Recorder()
    facts.monitoring(rec)
    assert rec.facts["thanos"]["stores"]["sidecar_connected"] is False
    assert rec.verdicts == []


# ─── Hardware ────────────────────────────────────────────────────────────────


def test_host_records_each_metric_group_under_its_own_key(monkeypatch):
    monkeypatch.setattr(
        facts.hardware, "snapshot", lambda: {"cpu": {"load": {}}, "memory": {}, "disk": {}}
    )
    rec = Recorder()
    facts.host(rec)
    assert set(rec.facts) == {"cpu", "memory", "disk"}


def test_host_records_an_unreadable_proc_as_a_fact(monkeypatch):
    def boom():
        raise OSError("no /proc")

    monkeypatch.setattr(facts.hardware, "snapshot", boom)
    rec = Recorder()
    facts.host(rec)
    assert "error" in rec.facts
    assert rec.verdicts == []


# ─── Registry wiring ─────────────────────────────────────────────────────────


def test_full_depth_is_a_superset_of_standard():
    from sk3s_verify.checks import build_registry

    reg = build_registry()
    standard = registry.select(reg, registry.STANDARD)
    full = registry.select(reg, registry.FULL)
    assert len(full) > len(standard)
    assert standard == full[: len(standard)]


def test_no_fact_collector_runs_at_standard_depth():
    from sk3s_verify.checks import build_registry

    selected = registry.select(build_registry(), registry.STANDARD)
    assert not any(check.run.__module__.endswith("checks.facts") for check in selected)


def test_every_full_check_is_a_fact_collector():
    from sk3s_verify.checks import build_registry

    full_only = [c for c in build_registry() if c.depth == registry.FULL]
    assert full_only
    assert all(c.run.__module__.endswith("checks.facts") for c in full_only)


# ─── Tailscale entrypoint ────────────────────────────────────────────────────


def ingress(name="tailnet-entrypoint", namespace="kube-system", service="traefik", port=8000):
    return {
        "metadata": {"name": name, "namespace": namespace},
        "spec": {
            "ingressClassName": "tailscale",
            "rules": [
                {
                    "http": {
                        "paths": [
                            {"backend": {"service": {"name": service, "port": {"number": port}}}}
                        ]
                    }
                }
            ],
        },
        "status": {"loadBalancer": {"ingress": [{"hostname": "sk3s.example.ts.net"}]}},
    }


def test_the_entrypoint_is_found_outside_the_tailscale_namespace(monkeypatch):
    """It fronts Traefik, so it lives where Traefik does — kube-system today.

    Looking it up in the tailscale namespace is the obvious wrong guess, and it
    reported 'not found' on a perfectly healthy cluster.
    """
    monkeypatch.setattr(facts.kube, "run_json", lambda *a, **k: {"items": [ingress()]})
    found, error = facts.entrypoint_ingress()
    assert error is None
    assert found["metadata"]["namespace"] == "kube-system"


def test_a_missing_entrypoint_is_reported_with_a_reason(monkeypatch):
    monkeypatch.setattr(facts.kube, "run_json", lambda *a, **k: {"items": []})
    found, error = facts.entrypoint_ingress()
    assert found is None
    assert "no Ingress named tailnet-entrypoint" in error


def test_the_backend_service_is_read_off_the_ingress_rules():
    assert facts._backend_of(ingress()) == {
        "namespace": "kube-system",
        "service": "traefik",
        "port": 8000,
    }


def test_an_ingress_without_a_backend_is_reported_not_probed(monkeypatch):
    bare = ingress()
    bare["spec"]["rules"] = []
    monkeypatch.setattr(facts.kube, "run_json", lambda *a, **k: {"items": [bare]})
    rec = Recorder()
    facts.tailscale(rec)
    assert rec.facts["backend"] == {"error": "ingress defines no backend service"}
    assert rec.verdicts == []


def test_the_entrypoint_hostname_is_recorded(monkeypatch):
    monkeypatch.setattr(facts.kube, "run_json", lambda *a, **k: {"items": [ingress()]})
    monkeypatch.setattr(
        facts.http, "probe", lambda *a, **k: {"url": "u", "status": 404, "body": "", "error": None}
    )
    rec = Recorder()
    facts.tailscale(rec)
    assert rec.facts["entrypoint"]["hostnames"] == ["sk3s.example.ts.net"]
    # Any status proves the tsnet listener is up, including Traefik's 404.
    assert rec.facts["backend"]["status"] == 404


# ─── Path prefixes ───────────────────────────────────────────────────────────
#
# Both services sit behind a path-based Ingress. Probing the bare path returns
# 404 from a perfectly healthy server — a wrong reading, which is worse than no
# reading, because a fact nobody grades is still a fact somebody believes.


def test_prometheus_route_prefix_is_read_from_the_cr(monkeypatch):
    payload = {"items": [{"spec": {"routePrefix": "/prometheus"}}]}
    monkeypatch.setattr(facts.kube, "run_json", lambda *a, **k: payload)
    assert facts.prometheus_route_prefix() == "/prometheus"


def test_a_root_route_prefix_normalises_to_empty(monkeypatch):
    """spec.routePrefix defaults to "/", which must not become a double slash."""
    monkeypatch.setattr(
        facts.kube, "run_json", lambda *a, **k: {"items": [{"spec": {"routePrefix": "/"}}]}
    )
    assert facts.prometheus_route_prefix() == ""


def test_route_prefix_is_empty_when_prometheus_is_not_installed(monkeypatch):
    monkeypatch.setattr(facts.kube, "run_json", unavailable)
    assert facts.prometheus_route_prefix() == ""


def test_prometheus_is_probed_under_its_route_prefix(monkeypatch):
    seen = []

    def record(namespace, service, path, **kwargs):
        seen.append(path)
        return {"url": "u", "status": 200, "body": "", "error": None}

    monkeypatch.setattr(facts, "prometheus_service", lambda: "prom")
    monkeypatch.setattr(facts, "prometheus_route_prefix", lambda: "/prometheus")
    monkeypatch.setattr(facts.http, "probe", record)
    result = facts._prometheus()
    assert seen == ["/prometheus/-/healthy", "/prometheus/-/ready"]
    assert result["route_prefix"] == "/prometheus"


def test_argocd_root_path_is_read_from_the_params_configmap(monkeypatch):
    payload = {"data": {"server.rootpath": "/argocd"}}
    monkeypatch.setattr(facts.kube, "run_json", lambda *a, **k: payload)
    assert facts.argocd_root_path() == "/argocd"


def test_argocd_root_path_is_empty_when_served_at_the_root(monkeypatch):
    monkeypatch.setattr(facts.kube, "run_json", lambda *a, **k: {"data": {}})
    assert facts.argocd_root_path() == ""


def test_argocd_login_is_probed_under_its_root_path(monkeypatch):
    seen = []

    def record(namespace, service, path, **kwargs):
        seen.append(path)
        return {"url": "u", "status": 303, "body": "", "error": None}

    monkeypatch.setattr(facts, "argocd_root_path", lambda: "/argocd")
    monkeypatch.setattr(facts.http, "probe", record)
    monkeypatch.setattr(facts.kube, "run_json", lambda *a, **k: {"items": []})
    rec = Recorder()
    facts.argocd(rec)
    assert seen == ["/argocd/auth/login"]
    assert rec.facts["login_route"]["redirect"] == "redirect issued"


def test_external_secrets_reports_both_store_kinds(monkeypatch):
    monkeypatch.setattr(facts.kube, "run_json", lambda *a, **k: {"items": []})
    rec = Recorder()
    facts.external_secrets(rec)
    assert set(rec.facts) == {"external_secrets", "cluster_secret_stores", "secret_stores"}
