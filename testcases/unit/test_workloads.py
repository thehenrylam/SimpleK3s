"""Workload readiness, including the zero-replica blind spot (#111)."""

import pytest
from sk3s_verify import kube, workloads


def _obj(monkeypatch, payload):
    monkeypatch.setattr(kube, "run_json", lambda *a, **k: payload)


def test_ready_when_all_replicas_ready(monkeypatch):
    _obj(monkeypatch, {"spec": {"replicas": 2}, "status": {"readyReplicas": 2}})
    ok, message = workloads.state("deployment", "monitoring", "grafana")
    assert ok
    assert "2/2" in message


def test_scaled_to_zero_is_not_ready(monkeypatch):
    # Verified live: `kubectl rollout status` reports SUCCESS here and the old
    # check reported "is ready" while the workload was entirely absent.
    _obj(monkeypatch, {"spec": {"replicas": 0}, "status": {}})
    ok, message = workloads.state("deployment", "monitoring", "prometheus-grafana")
    assert not ok
    assert "scaled to 0" in message


def test_partially_ready_is_not_ready(monkeypatch):
    _obj(monkeypatch, {"spec": {"replicas": 3}, "status": {"readyReplicas": 1}})
    ok, message = workloads.state("deployment", "kyverno", "admission")
    assert not ok
    assert "1/3" in message


def test_daemonset_uses_its_own_fields(monkeypatch):
    _obj(monkeypatch, {"status": {"desiredNumberScheduled": 3, "numberReady": 3}})
    ok, _ = workloads.state("daemonset", "longhorn-system", "longhorn-manager")
    assert ok


def test_daemonset_scheduled_nowhere_is_not_ready(monkeypatch):
    _obj(monkeypatch, {"status": {"desiredNumberScheduled": 0, "numberReady": 0}})
    ok, message = workloads.state("daemonset", "longhorn-system", "longhorn-manager")
    assert not ok
    assert "scaled to 0" in message


def test_missing_replica_count_is_unavailable_not_healthy(monkeypatch):
    _obj(monkeypatch, {"spec": {}, "status": {}})
    with pytest.raises(kube.Unavailable):
        workloads.state("deployment", "monitoring", "grafana")


def test_unknown_kind_is_a_programming_error(monkeypatch):
    with pytest.raises(ValueError):
        workloads.state("cronjob", "kube-system", "descheduler")
