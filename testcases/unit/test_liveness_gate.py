"""The liveness gate: what a node reports when it cannot see the cluster.

Observed live on sk3s-birch. A replacement node-0 that never installed k3s (the
#117 guard refused to guess) reported all 48 checks FAILED, and the host then
reported "nodes disagree" on all 15 sections. Every line was true and none was
useful — the one fact worth reading was buried under sixty restating it.

Two rules come out of that, and both are pinned here:
  * a node that fails the liveness floor stops, and says so once;
  * a node that never saw the cluster is an ABSENT vote, not a dissenting one.
"""

import pytest
import sk3s_status
from sk3s_verify import registry
from sk3s_verify.checks import build_registry


def check(section, result="passed", message="m"):
    return {"section": section, "result": result, "message": message}


def document(*checks):
    return {"checks": list(checks)}


# ─── The gate fires ──────────────────────────────────────────────────────────


def unreachable(rec):
    raise registry.kube.Unavailable("kubectl is not installed")


def healthy(rec):
    rec.passed("fine")


def test_a_failed_gate_stops_the_run_and_says_so_once():
    reg = [
        registry.Check(registry.GATE_SECTION, registry.QUICK, unreachable),
        registry.Check("nodes", registry.QUICK, healthy),
        registry.Check("traefik", registry.STANDARD, healthy),
        registry.Check("argocd", registry.STANDARD, healthy),
    ]
    results = registry.run_all(reg, registry.STANDARD)
    counts = results.counts
    assert counts[registry.FAILED] == 1
    assert counts[registry.SKIPPED] == 1
    assert counts[registry.PASSED] == 0
    assert "3 further check(s) not attempted" in results.checks[-1]["message"]
    assert registry.GATE_MESSAGE in results.checks[-1]["message"]


def test_the_remainder_is_skipped_never_passed():
    """Those checks were not verified. Absence is never success (#110)."""
    reg = [
        registry.Check(registry.GATE_SECTION, registry.QUICK, unreachable),
        registry.Check("traefik", registry.STANDARD, healthy),
    ]
    results = registry.run_all(reg, registry.STANDARD)
    assert [c["result"] for c in results.checks] == [registry.FAILED, registry.SKIPPED]


def test_a_healthy_gate_runs_everything():
    reg = [
        registry.Check(registry.GATE_SECTION, registry.QUICK, healthy),
        registry.Check("nodes", registry.QUICK, healthy),
        registry.Check("traefik", registry.STANDARD, healthy),
    ]
    results = registry.run_all(reg, registry.STANDARD)
    assert results.counts[registry.PASSED] == 3
    assert results.counts[registry.SKIPPED] == 0


def test_a_failure_that_is_not_the_gate_does_not_stop_the_run():
    """coredns being down says nothing about whether Traefik is up."""

    def broken(rec):
        rec.failed("coredns has 0/1 replicas ready")

    reg = [
        registry.Check(registry.GATE_SECTION, registry.QUICK, healthy),
        registry.Check("kube_system", registry.QUICK, broken),
        registry.Check("traefik", registry.STANDARD, healthy),
    ]
    results = registry.run_all(reg, registry.STANDARD)
    assert results.counts[registry.PASSED] == 2
    assert results.counts[registry.FAILED] == 1
    assert results.counts[registry.SKIPPED] == 0


def test_no_trailing_skip_when_the_gate_is_the_only_check():
    reg = [registry.Check(registry.GATE_SECTION, registry.QUICK, unreachable)]
    results = registry.run_all(reg, registry.QUICK)
    assert [c["result"] for c in results.checks] == [registry.FAILED]


def test_the_gate_is_the_first_check_in_the_real_registry():
    """A gate that runs late gates nothing."""
    assert build_registry()[0].section == registry.GATE_SECTION


# ─── observed_cluster, on both sides ─────────────────────────────────────────


def test_a_node_that_failed_the_gate_did_not_observe_the_cluster():
    doc = document(check(registry.GATE_SECTION, "failed"))
    assert registry.observed_cluster(doc) is False
    assert sk3s_status.observed_cluster(doc) is False


def test_a_node_that_passed_the_gate_did_observe_it():
    doc = document(check(registry.GATE_SECTION), check("traefik", "failed"))
    assert registry.observed_cluster(doc) is True
    assert sk3s_status.observed_cluster(doc) is True


def test_the_host_and_the_node_agree_on_which_section_is_the_gate():
    """Two constants that must match, so a test matches them."""
    assert sk3s_status.GATE_SECTION == registry.GATE_SECTION


# ─── The host stops treating it as dissent ───────────────────────────────────


def test_a_node_with_no_k3s_is_not_counted_as_disagreeing():
    """The live symptom: 15 sections reported as disagreements."""
    nodes = {
        "i-broken": {"document": document(check(registry.GATE_SECTION, "failed"))},
        "i-ok-1": {"document": document(check(registry.GATE_SECTION), check("traefik"))},
        "i-ok-2": {"document": document(check(registry.GATE_SECTION), check("traefik"))},
    }
    assert sk3s_status.disagreements(nodes) == []


def test_a_genuine_split_between_observing_nodes_is_still_caught():
    nodes = {
        "i-ok-1": {"document": document(check(registry.GATE_SECTION), check("argocd"))},
        "i-ok-2": {"document": document(check(registry.GATE_SECTION), check("argocd", "failed"))},
    }
    assert [d["section"] for d in sk3s_status.disagreements(nodes)] == ["argocd"]


def test_an_all_broken_cluster_reports_no_disagreement_rather_than_crashing():
    nodes = {n: {"document": document(check(registry.GATE_SECTION, "failed"))} for n in "ab"}
    assert sk3s_status.disagreements(nodes) == []


# ─── The e2e picks a reference that saw the cluster ───────────────────────────


def test_the_e2e_prefers_an_observing_node_as_its_reference():
    import simplek3s_e2e as e2e

    broken = document(check(registry.GATE_SECTION, "failed"))
    good = document(check(registry.GATE_SECTION), check("traefik"), check("argocd"))
    for d in (broken, good):
        d.update(result="failed", facts={}, generation={"stale": False})
    # "i-aaa" sorts first, so a naive first-readable rule would pick the broken one.
    report = {"nodes": {"i-aaa": {"document": broken}, "i-bbb": {"document": good}}}
    snapshot = e2e.build_snapshot(report)
    assert "traefik" in snapshot["checks"]


def test_the_e2e_falls_back_when_no_node_observed_the_cluster():
    import simplek3s_e2e as e2e

    broken = document(check(registry.GATE_SECTION, "failed"))
    broken.update(result="failed", facts={}, generation={"stale": None})
    snapshot = e2e.build_snapshot({"nodes": {"i-aaa": {"document": broken}}})
    assert snapshot["checks"] == {registry.GATE_SECTION: "failed"}


@pytest.mark.parametrize("missing", [{}, {"checks": []}])
def test_a_document_with_no_checks_counts_as_observing(missing):
    """Defensive: absent gate evidence must not silently mute a node."""
    assert registry.observed_cluster(missing) is True
