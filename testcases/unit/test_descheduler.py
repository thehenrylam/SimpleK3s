"""Descheduler health.

Before this, the check recorded exactly one assertion — that the CronJob object
exists. These tests pin the two states where that assertion passed while the
descheduler was doing nothing at all.
"""

from sk3s_verify.checks import subsystems


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


def job(name, state="complete", created="2026-09-09T10:00:00Z", owner="descheduler"):
    conditions = {
        "complete": [{"type": "Complete", "status": "True"}],
        "failed": [{"type": "Failed", "status": "True"}],
        "active": [],
    }[state]
    meta = {"name": name, "namespace": "kube-system", "creationTimestamp": created}
    if owner:
        meta["ownerReferences"] = [{"kind": "CronJob", "name": owner}]
    return {"metadata": meta, "status": {"conditions": conditions}}


def wire(monkeypatch, suspend=False, jobs=(), present=True):
    monkeypatch.setattr(subsystems.kube, "exists", lambda args, timeout=30: present)

    def run_json(args, timeout=30):
        if "cronjob" in args:
            return {"spec": {"suspend": suspend}}
        return {"items": list(jobs)}

    monkeypatch.setattr(subsystems.kube, "run_json", run_json)


# ─── job_state ───────────────────────────────────────────────────────────────


def test_job_state_reads_the_terminal_conditions():
    assert subsystems.job_state(job("a", "complete")) == "complete"
    assert subsystems.job_state(job("a", "failed")) == "failed"
    assert subsystems.job_state(job("a", "active")) == "active"


# ─── latest_finished_job ─────────────────────────────────────────────────────


def test_latest_finished_job_picks_the_newest():
    items = [
        job("old", "complete", created="2026-09-09T09:00:00Z"),
        job("new", "failed", created="2026-09-09T11:00:00Z"),
    ]
    assert subsystems.latest_finished_job(items, "descheduler")[1:] == ("new", "failed")


def test_latest_finished_job_ignores_unrelated_jobs():
    """kube-system also holds helm-install-* Jobs whose failures are not ours."""
    items = [job("helm-install-traefik", "failed", owner="helm-install-traefik")]
    assert subsystems.latest_finished_job(items, "descheduler") is None


def test_latest_finished_job_ignores_a_run_still_in_flight():
    assert subsystems.latest_finished_job([job("now", "active")], "descheduler") is None


# ─── descheduler ─────────────────────────────────────────────────────────────


def test_descheduler_passes_when_active_and_its_last_run_completed(monkeypatch):
    wire(monkeypatch, jobs=[job("descheduler-1")])
    rec = Recorder()
    subsystems.descheduler(rec)
    assert rec.results == ["passed", "passed"]


def test_a_suspended_cronjob_fails_though_the_object_exists(monkeypatch):
    """It is present, it looks healthy, and it will never evict anything."""
    wire(monkeypatch, suspend=True, jobs=[job("descheduler-1")])
    rec = Recorder()
    subsystems.descheduler(rec)
    assert rec.results == ["failed", "passed"]
    assert "SUSPENDED" in rec.entries[0][1]


def test_a_failing_latest_run_fails(monkeypatch):
    wire(monkeypatch, jobs=[job("descheduler-1", "failed")])
    rec = Recorder()
    subsystems.descheduler(rec)
    assert rec.results == ["passed", "failed"]


def test_a_cluster_younger_than_the_schedule_is_skipped_not_passed(monkeypatch):
    wire(monkeypatch, jobs=[])
    rec = Recorder()
    subsystems.descheduler(rec)
    assert rec.results == ["passed", "skipped"]


def test_descheduler_is_skipped_when_not_deployed(monkeypatch):
    wire(monkeypatch, present=False)
    rec = Recorder()
    subsystems.descheduler(rec)
    assert rec.results == ["skipped"]
