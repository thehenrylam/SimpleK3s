"""Cluster-wide sweep checks.

The sweeps are graded against the whole cluster, so the failure mode that
matters most is a FALSE PASS on an empty or partial answer — the same defect
class as #156. Those cases are asserted explicitly rather than left implied.
"""

import pytest
from sk3s_verify import registry
from sk3s_verify.checks import sweep


class Recorder:
    """A SectionRecorder stand-in that keeps what was recorded."""

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


def deployment(name, namespace="default", want=1, ready=1):
    return {
        "metadata": {"name": name, "namespace": namespace},
        "spec": {"replicas": want},
        "status": {"readyReplicas": ready},
    }


def daemonset(name, namespace="default", want=3, ready=3):
    return {
        "metadata": {"name": name, "namespace": namespace},
        "status": {"desiredNumberScheduled": want, "numberReady": ready},
    }


def pod(name, namespace="default", phase="Running", waiting=None, reason=None):
    status = {"phase": phase}
    if reason:
        status["reason"] = reason
    if waiting:
        status["containerStatuses"] = [{"name": "app", "state": {"waiting": {"reason": waiting}}}]
    return {"metadata": {"name": name, "namespace": namespace}, "status": status}


def pvc(name, phase="Bound", namespace="monitoring"):
    return {"metadata": {"name": name, "namespace": namespace}, "status": {"phase": phase}}


def feed(monkeypatch, by_resource):
    """Stub kube.run_json, dispatching on the kubectl resource being listed."""

    def fake(args, timeout=30):
        for key, payload in by_resource.items():
            if key in args:
                return payload
        return {"items": []}

    monkeypatch.setattr(sweep.kube, "run_json", fake)


# ─── survey ──────────────────────────────────────────────────────────────────


def test_survey_reports_under_delivered_replicas():
    under, zeroed = sweep.survey(
        [deployment("web", want=3, ready=1)], "deployment", "spec.replicas", "status.readyReplicas"
    )
    assert zeroed == []
    assert under == ["default/deployment/web has 1/3 ready"]


def test_survey_separates_scaled_to_zero_from_broken():
    under, zeroed = sweep.survey(
        [deployment("paused", want=0, ready=0)],
        "deployment",
        "spec.replicas",
        "status.readyReplicas",
    )
    assert under == []
    assert zeroed == ["default/deployment/paused"]


def test_survey_treats_a_missing_replica_count_as_under_delivered():
    obj = {"metadata": {"name": "odd", "namespace": "x"}, "spec": {}, "status": {}}
    under, zeroed = sweep.survey([obj], "deployment", "spec.replicas", "status.readyReplicas")
    assert zeroed == []
    assert "did not report a replica count" in under[0]


def test_survey_reads_a_missing_ready_count_as_zero_not_as_satisfied():
    obj = {"metadata": {"name": "web", "namespace": "x"}, "spec": {"replicas": 2}, "status": {}}
    under, _ = sweep.survey([obj], "deployment", "spec.replicas", "status.readyReplicas")
    assert under == ["x/deployment/web has 0/2 ready"]


# ─── workloads ───────────────────────────────────────────────────────────────


def test_workloads_passes_when_everything_is_satisfied(monkeypatch):
    feed(
        monkeypatch,
        {
            "deployments": {"items": [deployment("web")]},
            "daemonsets": {"items": [daemonset("agent")]},
        },
    )
    rec = Recorder()
    sweep.workloads(rec)
    assert rec.results == ["passed"]
    assert "All 2 scheduled workloads" in rec.entries[0][1]


def test_workloads_fails_when_the_cluster_reports_nothing(monkeypatch):
    """An empty answer to a successful query is an anomaly, not a clean bill."""
    feed(monkeypatch, {})
    rec = Recorder()
    sweep.workloads(rec)
    assert rec.results == ["failed"]
    assert "no workloads at all" in rec.entries[0][1]


def test_workloads_fails_on_a_workload_no_named_check_covers(monkeypatch):
    feed(monkeypatch, {"deployments": {"items": [deployment("some-argocd-app", want=2, ready=0)]}})
    rec = Recorder()
    sweep.workloads(rec)
    assert "failed" in rec.results


def test_workloads_records_scaled_to_zero_as_skipped_never_passed(monkeypatch):
    feed(
        monkeypatch,
        {"deployments": {"items": [deployment("web"), deployment("grafana", want=0, ready=0)]}},
    )
    rec = Recorder()
    sweep.workloads(rec)
    assert rec.results == ["passed", "skipped"]
    assert "All 1 scheduled workloads" in rec.entries[0][1]
    assert "default/deployment/grafana" in rec.entries[1][1]


def test_workloads_covers_daemonsets_by_their_own_status_fields(monkeypatch):
    feed(monkeypatch, {"daemonsets": {"items": [daemonset("longhorn", want=3, ready=2)]}})
    rec = Recorder()
    sweep.workloads(rec)
    assert rec.results == ["failed"]
    assert "1 of 1 workloads" in rec.entries[0][1]


# ─── pod health ──────────────────────────────────────────────────────────────


def test_pod_health_ignores_completed_job_pods(monkeypatch):
    feed(monkeypatch, {"pods": {"items": [pod("helm-install", phase="Succeeded")]}})
    rec = Recorder()
    sweep.pod_health(rec)
    assert rec.results == ["passed"]


def test_pod_health_ignores_pods_that_are_merely_starting(monkeypatch):
    """ContainerCreating during a rollout must not fail the deploy gate."""
    feed(
        monkeypatch, {"pods": {"items": [pod("new", phase="Pending", waiting="ContainerCreating")]}}
    )
    rec = Recorder()
    sweep.pod_health(rec)
    assert rec.results == ["passed"]


@pytest.mark.parametrize("reason", sorted(sweep.BLOCKED_REASONS))
def test_pod_health_fails_on_every_blocked_reason(monkeypatch, reason):
    feed(monkeypatch, {"pods": {"items": [pod("stuck", waiting=reason)]}})
    rec = Recorder()
    sweep.pod_health(rec)
    assert rec.results == ["failed"]


def test_pod_health_fails_on_a_failed_phase(monkeypatch):
    feed(monkeypatch, {"pods": {"items": [pod("evicted", phase="Failed", reason="Evicted")]}})
    rec = Recorder()
    sweep.pod_health(rec)
    assert rec.results == ["failed"]


def test_pod_health_inspects_init_containers_too():
    findings = sweep.unhealthy(
        [
            {
                "metadata": {"name": "app", "namespace": "argocd"},
                "status": {
                    "phase": "Pending",
                    "initContainerStatuses": [
                        {"name": "wait", "state": {"waiting": {"reason": "CrashLoopBackOff"}}}
                    ],
                },
            }
        ]
    )
    assert findings == ["argocd/app container wait: CrashLoopBackOff"]


def test_pod_health_fails_when_no_pods_are_returned(monkeypatch):
    feed(monkeypatch, {})
    rec = Recorder()
    sweep.pod_health(rec)
    assert rec.results == ["failed"]


# ─── storage ─────────────────────────────────────────────────────────────────


def test_storage_passes_when_every_claim_is_bound(monkeypatch):
    feed(monkeypatch, {"pvc": {"items": [pvc("grafana"), pvc("prometheus")]}})
    rec = Recorder()
    sweep.storage(rec)
    assert rec.results == ["passed"]


def test_storage_fails_on_a_pending_claim(monkeypatch):
    feed(monkeypatch, {"pvc": {"items": [pvc("grafana"), pvc("prometheus", phase="Pending")]}})
    rec = Recorder()
    sweep.storage(rec)
    assert rec.results == ["failed"]
    assert "1 of 2 PVCs" in rec.entries[0][1]


def test_storage_skips_rather_than_passes_when_there_are_no_claims(monkeypatch):
    """No claims is legitimate; calling that healthy storage is not."""
    feed(monkeypatch, {})
    rec = Recorder()
    sweep.storage(rec)
    assert rec.results == ["skipped"]


# ─── failure propagation ─────────────────────────────────────────────────────


@pytest.mark.parametrize("check", [sweep.workloads, sweep.pod_health, sweep.storage])
def test_an_unavailable_cluster_is_a_failure_not_a_pass(monkeypatch, check):
    def unavailable(args, timeout=30):
        raise sweep.kube.Unavailable("connection refused")

    monkeypatch.setattr(sweep.kube, "run_json", unavailable)
    results = registry.run_all([registry.Check("s", registry.STANDARD, check)], registry.STANDARD)
    assert [entry["result"] for entry in results.checks] == ["failed"]
