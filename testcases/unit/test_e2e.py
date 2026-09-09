"""End-to-end grading.

The e2e no longer collects anything — sk3s status does that — so what is left to
test is the projection into a graded snapshot and the matcher's willingness to
FAIL. A grader that cannot fail is worse than no grader, so most of this file is
degradation cases.
"""

import json
import pathlib

import pytest
import simplek3s_e2e as e2e

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "testcases" / "e2e" / "snapshot.example.json"
SHEET = ROOT / "testcases" / "e2e" / "answersheet.default.json"


@pytest.fixture
def snapshot():
    return json.loads(FIXTURE.read_text())


@pytest.fixture
def sheet():
    return json.loads(SHEET.read_text())


def grade(sheet, snapshot):
    checks = []
    e2e.evaluate(sheet, snapshot, [], checks)
    return {
        "red": [c for c in checks if c["status"] == e2e.RED],
        "yellow": [c for c in checks if c["status"] == e2e.YELLOW],
        "green": [c for c in checks if c["status"] == e2e.GREEN],
    }


# ─── The healthy baseline ────────────────────────────────────────────────────


def test_the_default_sheet_passes_a_healthy_snapshot(sheet, snapshot):
    result = grade(sheet, snapshot)
    assert result["red"] == []
    assert result["yellow"] == []
    assert result["green"]


# ─── Degradation: it must actually fail ──────────────────────────────────────


def test_a_failed_check_section_fails_the_grade(sheet, snapshot):
    snapshot["checks"]["argocd"] = "failed"
    assert [".".join(c["path"]) for c in grade(sheet, snapshot)["red"]] == ["checks.argocd"]


def test_a_core_section_may_not_be_skipped(sheet, snapshot):
    """Optional subsystems may be absent. There is no cluster without CoreDNS."""
    snapshot["checks"]["kube_system"] = "skipped"
    assert grade(sheet, snapshot)["red"]


def test_an_optional_section_may_be_skipped(sheet, snapshot):
    snapshot["checks"]["tailscale"] = "skipped"
    assert grade(sheet, snapshot)["red"] == []


def test_an_unreadable_node_fails_rather_than_being_skipped(sheet, snapshot):
    """The #110 shape: a node we could not check is not a node that passed."""
    node = next(iter(snapshot["nodes"]))
    snapshot["nodes"][node] = {"__error__": "unreachable over SSM"}
    red = grade(sheet, snapshot)["red"]
    assert len(red) == 1
    assert "not collected" in red[0]["message"]


def test_a_dead_grafana_database_fails(sheet, snapshot):
    """Grafana with an unreachable database still reports Ready to Kubernetes."""
    snapshot["facts"]["monitoring.grafana"]["database"] = "failed"
    assert grade(sheet, snapshot)["red"]


def test_a_disconnected_thanos_sidecar_fails(sheet, snapshot):
    """Every pod looks healthy while Grafana silently loses recent data."""
    snapshot["facts"]["monitoring.thanos"]["stores"]["sidecar_connected"] = False
    assert grade(sheet, snapshot)["red"]


def test_a_200_on_the_argocd_login_route_fails(sheet, snapshot):
    """200 is the SPA fallback — it means the OIDC route was never registered."""
    snapshot["facts"]["argocd.login_route"]["status"] = 200
    snapshot["facts"]["argocd.login_route"]["redirect"] = None
    assert grade(sheet, snapshot)["red"]


def test_an_unreachable_tailscale_backend_fails(sheet, snapshot):
    """A 404 is fine (unmatched Host); a transport error is not."""
    snapshot["facts"]["tailscale.backend"]["error"] = "ConnectionRefusedError()"
    assert grade(sheet, snapshot)["red"]


def test_a_404_from_the_tailscale_backend_is_accepted(sheet, snapshot):
    snapshot["facts"]["tailscale.backend"]["status"] = 404
    assert grade(sheet, snapshot)["red"] == []


def test_a_failing_overall_verdict_fails(sheet, snapshot):
    snapshot["verdict"] = "failed"
    assert grade(sheet, snapshot)["red"]


def test_nodes_disagreeing_fails(sheet, snapshot):
    snapshot["disagreements"] = 2
    assert grade(sheet, snapshot)["red"]


# ─── Warnings, not failures ──────────────────────────────────────────────────


def test_a_full_disk_warns_rather_than_failing(sheet, snapshot):
    node = next(iter(snapshot["nodes"]))
    snapshot["nodes"][node]["hardware"]["disk"]["usage"] = 91.0
    result = grade(sheet, snapshot)
    assert result["red"] == []
    assert len(result["yellow"]) == 1


def test_an_unknown_generation_is_accepted(sheet, snapshot):
    """null means no stamp or unreadable bucket — reported, never fatal."""
    node = next(iter(snapshot["nodes"]))
    snapshot["nodes"][node]["generation_stale"] = None
    assert grade(sheet, snapshot)["red"] == []


def test_a_stale_node_fails(sheet, snapshot):
    node = next(iter(snapshot["nodes"]))
    snapshot["nodes"][node]["generation_stale"] = True
    assert grade(sheet, snapshot)["red"]


# ─── Snapshot projection ─────────────────────────────────────────────────────


def report(checks, facts=None, result="passed", stale=False):
    document = {
        "result": result,
        "checks": checks,
        "facts": facts or {},
        "generation": {"stale": stale},
    }
    return {"cluster": "c", "result": result, "nodes": {"i-1": {"document": document}}}


def test_section_verdicts_take_the_worst_result():
    checks = [
        {"section": "tailscale", "result": "passed", "message": "a"},
        {"section": "tailscale", "result": "failed", "message": "b"},
        {"section": "tailscale", "result": "skipped", "message": "c"},
    ]
    assert e2e.section_verdicts(checks) == {"tailscale": "failed"}


def test_hardware_is_projected_per_node_everything_else_is_cluster_scoped():
    facts = {"hardware.disk": {"usage": 10}, "monitoring.grafana": {"status": 200}}
    snapshot = e2e.build_snapshot(report([], facts))
    assert snapshot["nodes"]["i-1"]["hardware"] == {"disk": {"usage": 10}}
    assert "hardware.disk" not in snapshot["facts"]
    assert snapshot["facts"] == {"monitoring.grafana": {"status": 200}}


def test_an_unreadable_node_becomes_an_error_subtree():
    out = e2e.build_snapshot({"nodes": {"i-1": {"error": "unreachable"}}})
    assert out["nodes"]["i-1"] == {"__error__": "unreachable"}


def test_no_readable_document_is_an_error_not_an_empty_pass():
    """Empty checks would grade as 'nothing wrong'. It must read as unknown."""
    out = e2e.build_snapshot({"nodes": {"i-1": {"error": "unreachable"}}})
    assert "__error__" in out["checks"]
    assert "__error__" in out["facts"]


def test_disagreements_are_carried_as_a_count():
    out = e2e.build_snapshot({**report([]), "disagreements": [{"section": "argocd"}]})
    assert out["disagreements"] == 1


# ─── Collection plumbing ─────────────────────────────────────────────────────


def test_status_argv_requests_full_depth_and_json():
    argv = e2e.status_argv("/tool", "prof", "nick", "us-east-1")
    assert argv[-3:] == ["--depth", "full", "--json"]
    assert argv[2:5] == ["prof", "nick", "us-east-1"]


def test_status_argv_allows_everything_to_be_inferred():
    assert e2e.status_argv("/tool", None, None, None)[-3:] == ["--depth", "full", "--json"]


def test_a_positional_cannot_be_supplied_without_the_ones_before_it():
    """argparse would silently bind region to nickname."""
    with pytest.raises(SystemExit):
        e2e.status_argv("/tool", None, None, "us-east-1")


def test_unparseable_status_output_is_fatal(monkeypatch):
    """A report we cannot read is not a cluster with nothing wrong."""

    class Done:
        returncode = 1
        stdout = "Traceback..."
        stderr = "boom"

    monkeypatch.setattr(e2e.subprocess, "run", lambda *a, **k: Done())
    with pytest.raises(SystemExit):
        e2e.collect("/tool", "p", "n", "r")


def test_an_unhealthy_cluster_still_gets_graded(monkeypatch):
    """sk3s status exits 1 on a failing cluster; grading that is the point."""

    class Done:
        returncode = 1
        stdout = json.dumps({"cluster": "c", "result": "failed", "nodes": {}})
        stderr = ""

    monkeypatch.setattr(e2e.subprocess, "run", lambda *a, **k: Done())
    assert e2e.collect("/tool", "p", "n", "r")["result"] == "failed"
