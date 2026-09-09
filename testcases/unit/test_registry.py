"""Depth selection, section binding, and the failure semantics of the runner.

The rule under test: a check that did not run has NOT passed. Nothing here may
report success on absence, on an exception, or on an unanswerable query.
"""

import base64
import gzip
import json

from sk3s_verify import kube, registry
from sk3s_verify.__main__ import build_document, main
from sk3s_verify.registry import FULL, QUICK, STANDARD, Check


def _reg(*checks):
    return list(checks)


# ─── Depth ───────────────────────────────────────────────────────────────────


def test_depth_widens_rather_than_replaces():
    reg = _reg(
        Check("a", QUICK, lambda rec: rec.passed("quick")),
        Check("b", STANDARD, lambda rec: rec.passed("standard")),
        Check("c", FULL, lambda rec: rec.passed("full")),
    )
    assert [c.section for c in registry.select(reg, QUICK)] == ["a"]
    assert [c.section for c in registry.select(reg, STANDARD)] == ["a", "b"]
    assert [c.section for c in registry.select(reg, FULL)] == ["a", "b", "c"]


def test_declaration_order_is_report_order():
    reg = _reg(
        Check("z", QUICK, lambda rec: rec.passed("first")),
        Check("a", QUICK, lambda rec: rec.passed("second")),
    )
    results = registry.run_all(reg, QUICK)
    assert [c["section"] for c in results.checks] == ["z", "a"]


# ─── Section binding ─────────────────────────────────────────────────────────


def test_a_check_cannot_name_its_own_section():
    """The recorder is bound at registration, so the section on the record comes
    from the registry and not from anything the check says."""
    reg = _reg(Check("traefik", QUICK, lambda rec: rec.passed("ready")))
    results = registry.run_all(reg, QUICK)
    assert results.checks[0]["section"] == "traefik"


def test_the_same_function_registered_twice_reports_under_each_section():
    def shared(rec):
        rec.passed("ok")

    reg = _reg(Check("argocd", QUICK, shared), Check("grafana", QUICK, shared))
    results = registry.run_all(reg, QUICK)
    assert [c["section"] for c in results.checks] == ["argocd", "grafana"]


def test_facts_are_namespaced_by_section():
    reg = _reg(
        Check("monitoring", FULL, lambda rec: rec.fact("pods", [1])),
        Check("longhorn", FULL, lambda rec: rec.fact("pods", [2])),
    )
    results = registry.run_all(reg, FULL)
    # Two subsystems using the same key must not collide.
    assert results.facts == {"monitoring.pods": [1], "longhorn.pods": [2]}


def test_verdict_records_exactly_one_result_either_way():
    reg = _reg(
        Check("a", QUICK, lambda rec: rec.verdict(True, "up")),
        Check("b", QUICK, lambda rec: rec.verdict(False, "down")),
    )
    results = registry.run_all(reg, QUICK)
    assert [c["result"] for c in results.checks] == [registry.PASSED, registry.FAILED]


# ─── Failure semantics ───────────────────────────────────────────────────────


def test_unavailable_becomes_a_failure_not_a_skip():
    def unanswerable(rec):
        raise kube.Unavailable("connection refused")

    results = registry.run_all(_reg(Check("nodes", QUICK, unanswerable)), QUICK)
    assert results.counts == {registry.PASSED: 0, registry.FAILED: 1, registry.SKIPPED: 0}
    assert "connection refused" in results.checks[0]["detail"]
    assert results.checks[0]["section"] == "nodes"


def test_an_exploding_check_cannot_pass():
    def broken(rec):
        raise RuntimeError("boom")

    results = registry.run_all(_reg(Check("karpenter", QUICK, broken)), QUICK)
    assert results.counts[registry.FAILED] == 1
    assert "RuntimeError" in results.checks[0]["message"]


def test_a_check_that_records_nothing_and_throws_still_fails():
    """Silence is not an available outcome."""

    def silent(rec):
        raise kube.Unavailable("no answer")

    results = registry.run_all(_reg(Check("longhorn", QUICK, silent)), QUICK)
    assert len(results.checks) == 1
    assert results.checks[0]["result"] == registry.FAILED


def test_one_failing_check_does_not_abort_the_others():
    def explode(rec):
        raise RuntimeError()

    reg = _reg(Check("a", QUICK, explode), Check("b", QUICK, lambda rec: rec.passed("fine")))
    results = registry.run_all(reg, QUICK)
    assert results.counts == {registry.PASSED: 1, registry.FAILED: 1, registry.SKIPPED: 0}


def test_skipped_is_not_passed():
    reg = _reg(Check("tailscale", QUICK, lambda rec: rec.skipped("not deployed")))
    results = registry.run_all(reg, QUICK)
    assert results.counts[registry.SKIPPED] == 1
    assert results.counts[registry.PASSED] == 0


# ─── Document ────────────────────────────────────────────────────────────────


def test_document_reports_failed_when_any_check_failed():
    reg = _reg(
        Check("a", QUICK, lambda rec: rec.passed("ok")),
        Check("b", QUICK, lambda rec: rec.failed("nope")),
    )
    doc = build_document(QUICK, reg)
    assert doc["result"] == registry.FAILED
    assert doc["schema"] == 2
    assert doc["depth"] == QUICK
    assert doc["summary"]["total"] == 2


def test_skips_alone_do_not_fail_the_document():
    reg = _reg(Check("a", QUICK, lambda rec: rec.skipped("not deployed")))
    assert build_document(QUICK, reg)["result"] == registry.PASSED


def test_facts_carry_no_verdict():
    reg = _reg(Check("m", FULL, lambda rec: rec.fact("pods", [{"n": 1}])))
    doc = build_document(FULL, reg)
    assert doc["facts"] == {"m.pods": [{"n": 1}]}
    assert doc["summary"]["total"] == 0


def test_compressed_output_round_trips(capsys, monkeypatch):
    reg = _reg(Check("a", QUICK, lambda rec: rec.passed("ok")))
    monkeypatch.setattr("sk3s_verify.checks.build_registry", lambda: reg)
    rc = main(["--depth", "quick", "--compress"])
    payload = capsys.readouterr().out.strip()
    doc = json.loads(gzip.decompress(base64.b64decode(payload)).decode())
    assert rc == 0
    assert doc["checks"][0]["message"] == "ok"


def test_exit_code_reflects_the_verdict(capsys, monkeypatch):
    reg = _reg(Check("a", QUICK, lambda rec: rec.failed("nope")))
    monkeypatch.setattr("sk3s_verify.checks.build_registry", lambda: reg)
    assert main(["--depth", "quick"]) == 1
    capsys.readouterr()
