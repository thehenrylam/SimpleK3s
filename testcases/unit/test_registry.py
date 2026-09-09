"""Depth selection and the failure semantics of the runner.

The rule under test: a check that did not run has NOT passed. Nothing here may
report success on absence, an exception, or an unanswerable query.
"""

import base64
import gzip
import json

import pytest
from sk3s_verify import kube, registry
from sk3s_verify.__main__ import build_document, main


@pytest.fixture(autouse=True)
def isolated_registry(monkeypatch):
    """Each test gets its own registry; checks.py's real registrations are not
    in scope here and would otherwise try to reach a cluster."""
    monkeypatch.setattr(registry, "_REGISTRY", [])


def test_depth_widens_rather_than_replaces():
    registry.check("a", depth=registry.QUICK)(lambda rec: rec.passed("a", "quick"))
    registry.check("b", depth=registry.STANDARD)(lambda rec: rec.passed("b", "standard"))
    registry.check("c", depth=registry.FULL)(lambda rec: rec.passed("c", "full"))

    assert [c["section"] for c in registry.registered(registry.QUICK)] == ["a"]
    assert [c["section"] for c in registry.registered(registry.STANDARD)] == ["a", "b"]
    assert [c["section"] for c in registry.registered(registry.FULL)] == ["a", "b", "c"]


def test_unavailable_becomes_a_failure_not_a_skip():
    def unanswerable(rec):
        raise kube.Unavailable("connection refused")

    registry.check("nodes", depth=registry.QUICK)(unanswerable)
    rec = registry.run_all(registry.QUICK)

    assert rec.counts[registry.FAILED] == 1
    assert rec.counts[registry.PASSED] == 0
    assert rec.counts[registry.SKIPPED] == 0
    assert "connection refused" in rec.checks[0]["detail"]


def test_an_exploding_check_cannot_pass():
    def broken(rec):
        raise RuntimeError("boom")

    registry.check("karpenter", depth=registry.QUICK)(broken)
    rec = registry.run_all(registry.QUICK)

    assert rec.counts[registry.FAILED] == 1
    assert "RuntimeError" in rec.checks[0]["message"]


def test_one_failing_check_does_not_abort_the_others():
    registry.check("a", depth=registry.QUICK)(lambda rec: (_ for _ in ()).throw(RuntimeError()))
    registry.check("b", depth=registry.QUICK)(lambda rec: rec.passed("b", "fine"))
    rec = registry.run_all(registry.QUICK)
    assert rec.counts == {registry.PASSED: 1, registry.FAILED: 1, registry.SKIPPED: 0}


def test_skipped_is_not_passed():
    registry.check("tailscale", depth=registry.QUICK)(
        lambda rec: rec.skipped("tailscale", "not deployed")
    )
    rec = registry.run_all(registry.QUICK)
    assert rec.counts[registry.SKIPPED] == 1
    assert rec.counts[registry.PASSED] == 0


def test_document_reports_failed_when_any_check_failed():
    registry.check("a", depth=registry.QUICK)(lambda rec: rec.passed("a", "ok"))
    registry.check("b", depth=registry.QUICK)(lambda rec: rec.failed("b", "nope"))
    doc = build_document(registry.QUICK)
    assert doc["result"] == registry.FAILED
    assert doc["schema"] == 2
    assert doc["depth"] == registry.QUICK
    assert doc["summary"]["total"] == 2


def test_skips_alone_do_not_fail_the_document():
    registry.check("a", depth=registry.QUICK)(lambda rec: rec.skipped("a", "not deployed"))
    assert build_document(registry.QUICK)["result"] == registry.PASSED


def test_facts_are_reported_not_graded():
    registry.check("m", depth=registry.FULL)(lambda rec: rec.fact("m.pods", [{"n": 1}]))
    doc = build_document(registry.FULL)
    assert doc["facts"] == {"m.pods": [{"n": 1}]}
    # Facts contribute no verdict of their own.
    assert doc["summary"]["total"] == 0


def test_compressed_output_round_trips(capsys):
    registry.check("a", depth=registry.QUICK)(lambda rec: rec.passed("a", "ok"))
    rc = main(["--depth", "quick", "--compress"])
    payload = capsys.readouterr().out.strip()
    doc = json.loads(gzip.decompress(base64.b64decode(payload)).decode())
    assert rc == 0
    assert doc["checks"][0]["message"] == "ok"


def test_exit_code_reflects_the_verdict(capsys):
    registry.check("a", depth=registry.QUICK)(lambda rec: rec.failed("a", "nope"))
    assert main(["--depth", "quick"]) == 1
    capsys.readouterr()
