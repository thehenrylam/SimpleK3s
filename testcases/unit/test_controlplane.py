"""Control-plane component health.

The lease checks exist because presence is not health: K3s never garbage-
collects these leases, so the object outlives its holder. `now` is injected so
the staleness window is deterministic.
"""

import datetime

import pytest
from sk3s_verify import registry
from sk3s_verify.checks import core

NOW = datetime.datetime(2026, 9, 9, 16, 0, 0, tzinfo=datetime.timezone.utc)


class Recorder:
    def __init__(self):
        self.entries = []

    def passed(self, message):
        self.entries.append(("passed", message))

    def failed(self, message, detail=None):
        self.entries.append(("failed", message))

    def skipped(self, message):
        self.entries.append(("skipped", message))

    def verdict(self, ok, message):
        (self.passed if ok else self.failed)(message)

    @property
    def results(self):
        return [result for result, _ in self.entries]


def lease(seconds_ago=2):
    renewed = NOW - datetime.timedelta(seconds=seconds_ago)
    return {"spec": {"renewTime": renewed.isoformat().replace("+00:00", "Z")}}


def wire(monkeypatch, raw="ok", leases=None):
    monkeypatch.setattr(core.kube, "run", lambda args, timeout=30: raw)
    payload = lease() if leases is None else leases
    monkeypatch.setattr(core.kube, "run_json", lambda args, timeout=30: payload)


# ─── lease_stale_seconds ─────────────────────────────────────────────────────


def test_lease_window_defaults_when_unset(monkeypatch):
    monkeypatch.delenv("LEASE_STALE_SECONDS", raising=False)
    assert core.lease_stale_seconds() == core.DEFAULT_LEASE_STALE_SECONDS


def test_lease_window_reads_the_environment(monkeypatch):
    monkeypatch.setenv("LEASE_STALE_SECONDS", "15")
    assert core.lease_stale_seconds() == 15


@pytest.mark.parametrize("value", ["0", "-5", "sixty", "60.5"])
def test_a_malformed_lease_window_is_rejected_not_defaulted(monkeypatch, value):
    """#110: a bad value that silently defaults hides that the knob did nothing."""
    monkeypatch.setenv("LEASE_STALE_SECONDS", value)
    with pytest.raises(ValueError):
        core.lease_stale_seconds()


# ─── lease_age ───────────────────────────────────────────────────────────────


def test_lease_age_measures_from_renew_time():
    assert core.lease_age(lease(seconds_ago=30), now=NOW) == 30


def test_lease_age_is_none_when_never_renewed():
    assert core.lease_age({"spec": {}}, now=NOW) is None


def test_lease_age_is_false_when_the_timestamp_is_unreadable():
    assert core.lease_age({"spec": {"renewTime": "not-a-time"}}, now=NOW) is False


# ─── controlplane ────────────────────────────────────────────────────────────


def test_controlplane_passes_on_a_healthy_cluster(monkeypatch):
    wire(monkeypatch)
    rec = Recorder()
    core.controlplane(rec, now=NOW)
    assert rec.results == ["passed"] * 4


def test_controlplane_fails_when_an_endpoint_is_not_ok(monkeypatch):
    wire(monkeypatch, raw="[-]etcd failed")
    rec = Recorder()
    core.controlplane(rec, now=NOW)
    assert rec.results[:2] == ["failed", "failed"]


def test_controlplane_fails_a_stale_lease_though_the_object_exists(monkeypatch):
    """The scheduler is dead but its lease object is still there."""
    wire(monkeypatch, leases=lease(seconds_ago=3600))
    rec = Recorder()
    core.controlplane(rec, now=NOW)
    assert rec.results[2:] == ["failed", "failed"]
    assert "3600s ago" in rec.entries[2][1]


def test_controlplane_honours_a_custom_staleness_window(monkeypatch):
    monkeypatch.setenv("LEASE_STALE_SECONDS", "10")
    wire(monkeypatch, leases=lease(seconds_ago=30))
    rec = Recorder()
    core.controlplane(rec, now=NOW)
    assert rec.results[2:] == ["failed", "failed"]


def test_controlplane_fails_when_a_lease_is_unreadable(monkeypatch):
    def boom(args, timeout=30):
        raise core.kube.Unavailable("leases.coordination.k8s.io not found")

    monkeypatch.setattr(core.kube, "run", lambda args, timeout=30: "ok")
    monkeypatch.setattr(core.kube, "run_json", boom)
    rec = Recorder()
    core.controlplane(rec, now=NOW)
    assert rec.results == ["passed", "passed", "failed", "failed"]


def test_an_unreachable_api_is_a_failure_not_a_pass(monkeypatch):
    def boom(args, timeout=30):
        raise core.kube.Unavailable("connection refused")

    monkeypatch.setattr(core.kube, "run", boom)
    monkeypatch.setattr(core.kube, "run_json", boom)
    results = registry.run_all(
        [registry.Check("controlplane", registry.QUICK, core.controlplane)], registry.QUICK
    )
    assert {entry["result"] for entry in results.checks} == {"failed"}
