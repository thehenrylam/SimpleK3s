"""The analysis inside checks, tested without a cluster.

These are the parts with real logic — time windows, thresholds, and the OIDC
causality rule — as opposed to the kubectl plumbing covered elsewhere.
"""

import datetime

import pytest
from sk3s_verify.checks import apps, core, subsystems

NOW = datetime.datetime(2026, 9, 9, 12, 0, 0, tzinfo=datetime.timezone.utc)


def _iso(minutes_ago):
    return (NOW - datetime.timedelta(minutes=minutes_ago)).isoformat().replace("+00:00", "Z")


# ─── Windows and thresholds must not silently default (#110) ─────────────────


@pytest.mark.parametrize("bad", ["0", "-5", "abc", "12.5", " "])
def test_malformed_stability_window_raises(monkeypatch, bad):
    monkeypatch.setenv("STABILITY_WINDOW_SECONDS", bad)
    with pytest.raises(ValueError):
        core.stability_window()


def test_stability_window_defaults_when_unset(monkeypatch):
    monkeypatch.delenv("STABILITY_WINDOW_SECONDS", raising=False)
    assert core.stability_window() == core.DEFAULT_STABILITY_WINDOW_SECONDS


def test_malformed_stuck_minutes_raises(monkeypatch):
    monkeypatch.setenv("KARPENTER_NODECLAIM_STUCK_MINUTES", "soon")
    with pytest.raises(ValueError):
        subsystems.stuck_minutes()


# ─── Pod stability: the time-windowed restart check (#111 must preserve it) ──


def _pod(ns, name, container, *, restarts=0, last_finished=None, exit_code=None, phase="Running"):
    status = {"phase": phase, "containerStatuses": [{"name": container, "restartCount": restarts}]}
    cs = status["containerStatuses"][0]
    if last_finished is not None:
        cs["lastState"] = {"terminated": {"finishedAt": last_finished}}
    if exit_code is not None:
        cs["state"] = {"terminated": {"exitCode": exit_code, "finishedAt": last_finished}}
    return {"metadata": {"namespace": ns, "name": name}, "status": status}


def test_restart_inside_the_window_is_reported():
    pods = [_pod("argocd", "argocd-server-1", "server", restarts=1, last_finished=_iso(2))]
    found = core.recent_restarts(pods, window=300, now=NOW)
    assert len(found) == 1
    assert "argocd/argocd-server-1" in found[0]
    assert "restarted at" in found[0]


def test_restart_outside_the_window_is_ignored():
    pods = [_pod("argocd", "argocd-server-1", "server", restarts=1, last_finished=_iso(60))]
    assert core.recent_restarts(pods, window=300, now=NOW) == []


def test_a_rolling_replacement_does_not_register():
    """A new pod has no lastState. Verified live: a `sk3s refresh` rollout left
    pod_stability passing, while stopping k3s (in-place restarts) tripped it."""
    pods = [_pod("external-secrets", "es-new", "es", restarts=0)]
    assert core.recent_restarts(pods, window=300, now=NOW) == []


def test_unreadable_timestamp_is_reported_not_skipped():
    pods = [_pod("kube-system", "coredns-1", "coredns", restarts=1, last_finished="not-a-date")]
    found = core.recent_restarts(pods, window=300, now=NOW)
    assert found and "unreadable timestamp" in found[0]


def test_succeeded_pods_are_not_instability():
    pods = [_pod("batch", "job-1", "worker", restarts=1, last_finished=_iso(1), phase="Succeeded")]
    assert core.recent_restarts(pods, window=300, now=NOW) == []


def test_clean_exit_of_the_current_container_is_not_instability():
    pods = [_pod("batch", "job-2", "worker", exit_code=0, last_finished=_iso(1))]
    assert core.recent_restarts(pods, window=300, now=NOW) == []


def test_nonzero_exit_of_the_current_container_is_instability():
    pods = [_pod("batch", "job-3", "worker", exit_code=1, last_finished=_iso(1))]
    found = core.recent_restarts(pods, window=300, now=NOW)
    assert found and "terminated at" in found[0]


# ─── Karpenter stuck NodeClaims (#123) ───────────────────────────────────────


def _claim(name, *, created=None, deleting=None, ready=None):
    meta = {"name": name}
    if created:
        meta["creationTimestamp"] = created
    if deleting:
        meta["deletionTimestamp"] = deleting
    status = {}
    if ready is not None:
        status["conditions"] = [{"type": "Ready", "status": ready}]
    return {"metadata": meta, "status": status}


def test_healthy_ready_claim_is_not_stuck():
    claims = [_claim("nc-1", created=_iso(120), ready="True")]
    assert subsystems.stuck_nodeclaims(claims, 20, now=NOW) == []


def test_claim_deleting_past_the_threshold_is_stuck():
    claims = [_claim("nc-2", created=_iso(200), deleting=_iso(45), ready="True")]
    found = subsystems.stuck_nodeclaims(claims, 20, now=NOW)
    assert found and "drain is blocked" in found[0]


def test_claim_deleting_within_the_threshold_is_not_yet_stuck():
    claims = [_claim("nc-3", created=_iso(200), deleting=_iso(5), ready="True")]
    assert subsystems.stuck_nodeclaims(claims, 20, now=NOW) == []


def test_claim_that_never_became_ready_is_stuck():
    claims = [_claim("nc-4", created=_iso(45), ready="False")]
    found = subsystems.stuck_nodeclaims(claims, 20, now=NOW)
    assert found and "never joined" in found[0]


def test_young_unready_claim_is_still_launching():
    claims = [_claim("nc-5", created=_iso(3), ready="False")]
    assert subsystems.stuck_nodeclaims(claims, 20, now=NOW) == []


def test_deleting_takes_precedence_over_readiness():
    """A claim being deleted is judged on its deletion age, not its creation."""
    claims = [_claim("nc-6", created=_iso(500), deleting=_iso(1), ready="False")]
    assert subsystems.stuck_nodeclaims(claims, 20, now=NOW) == []


# ─── ArgoCD OIDC causality (#95 / #145) ──────────────────────────────────────


def _oidc(monkeypatch, secret_ts, pod_starts, labels=None):
    labels = {"app": "argocd-server"} if labels is None else labels

    def fake(args, **kwargs):
        if "secret" in args:
            return {"metadata": {"creationTimestamp": secret_ts}} if secret_ts else {"metadata": {}}
        if "deployment" in args:
            return {"spec": {"selector": {"matchLabels": labels}}}
        return {"items": [{"status": {"startTime": s}} for s in pod_starts]}

    monkeypatch.setattr(apps.kube, "run_json", fake)


def test_pod_started_after_the_secret_is_current(monkeypatch):
    _oidc(monkeypatch, _iso(10), [_iso(5)])
    assert apps.oidc_state() == "current"


def test_pod_started_before_the_secret_is_stale(monkeypatch):
    _oidc(monkeypatch, _iso(5), [_iso(10)])
    assert apps.oidc_state() == "stale"


def test_exact_tie_is_stale_because_the_boundary_is_ambiguous(monkeypatch):
    same = _iso(5)
    _oidc(monkeypatch, same, [same])
    assert apps.oidc_state() == "stale"


def test_oldest_running_pod_decides(monkeypatch):
    _oidc(monkeypatch, _iso(5), [_iso(1), _iso(30)])
    assert apps.oidc_state() == "stale"


def test_missing_secret_is_unknown_not_current(monkeypatch):
    _oidc(monkeypatch, None, [_iso(1)])
    assert apps.oidc_state() == "unknown"


def test_no_running_pods_is_unknown(monkeypatch):
    _oidc(monkeypatch, _iso(5), [])
    assert apps.oidc_state() == "unknown"


def test_unreachable_api_is_unknown(monkeypatch):
    def boom(args, **kwargs):
        raise apps.kube.Unavailable("connection refused")

    monkeypatch.setattr(apps.kube, "run_json", boom)
    assert apps.oidc_state() == "unknown"
