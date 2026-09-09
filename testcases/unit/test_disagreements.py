"""Cross-node reconciliation in the host status tool.

The whole point of fanning out to every control-plane node is that they should
agree. Getting "disagreement" wrong in either direction is costly: too eager and
healthy deploys fail, too lax and a diverging node passes unnoticed.
"""

import sk3s_status


def node(*checks):
    return {
        "document": {
            "checks": [dict(zip(("section", "result", "message"), c, strict=True)) for c in checks]
        }
    }


def sections_reported(out):
    return [item["section"] for item in out]


# ─── section_verdicts ────────────────────────────────────────────────────────


def test_a_section_collapses_to_its_worst_verdict():
    document = node(
        ("tailscale", "passed", "operator ready"),
        ("tailscale", "failed", "no ProxyClass"),
        ("tailscale", "skipped", "cert pending"),
    )["document"]
    assert sk3s_status.section_verdicts(document) == {"tailscale": "failed"}


def test_a_skip_outranks_a_pass_but_not_a_failure():
    document = node(
        ("storage", "passed", "bound"),
        ("storage", "skipped", "no claims"),
    )["document"]
    assert sk3s_status.section_verdicts(document) == {"storage": "skipped"}


# ─── disagreements ───────────────────────────────────────────────────────────


def test_identical_nodes_do_not_disagree():
    nodes = {
        "i-1": node(("workloads", "passed", "all 47 ready")),
        "i-2": node(("workloads", "passed", "all 47 ready")),
    }
    assert sk3s_status.disagreements(nodes) == []


def test_live_readings_in_the_message_are_not_a_disagreement():
    """The defect this replaced: same verdict, drifting wording, run marked FAIL."""
    nodes = {
        "i-1": node(("controlplane", "passed", "kube-scheduler renewed its lease 0s ago")),
        "i-2": node(("controlplane", "passed", "kube-scheduler renewed its lease 1s ago")),
        "i-3": node(("controlplane", "passed", "kube-scheduler renewed its lease 1s ago")),
    }
    assert sk3s_status.disagreements(nodes) == []


def test_differing_verdicts_are_reported():
    nodes = {
        "i-1": node(("argocd", "passed", "server ready")),
        "i-2": node(("argocd", "failed", "server has 0/1 replicas ready")),
    }
    out = sk3s_status.disagreements(nodes)
    assert sections_reported(out) == ["argocd"]
    assert out[0]["verdicts"] == {"i-1": "passed", "i-2": "failed"}


def test_a_differing_verdict_is_caught_even_when_the_message_matches():
    nodes = {
        "i-1": node(("storage", "passed", "same text")),
        "i-2": node(("storage", "failed", "same text")),
    }
    assert sections_reported(sk3s_status.disagreements(nodes)) == ["storage"]


def test_a_section_missing_from_one_node_is_a_disagreement():
    """A node running a different set of checks is a finding, not a pass."""
    nodes = {
        "i-1": node(("workloads", "passed", "ok"), ("storage", "passed", "ok")),
        "i-2": node(("workloads", "passed", "ok")),
    }
    out = sk3s_status.disagreements(nodes)
    assert sections_reported(out) == ["storage"]
    assert out[0]["verdicts"] == {"i-1": "passed", "i-2": sk3s_status.ABSENT}


def test_nodes_with_no_document_are_excluded_not_counted_as_absent():
    """An unreachable node is reported separately; it is not a disagreement."""
    nodes = {
        "i-1": node(("workloads", "passed", "ok")),
        "i-2": {"error": "unreachable"},
    }
    assert sk3s_status.disagreements(nodes) == []


def test_a_section_failing_on_every_node_is_agreement_not_disagreement():
    nodes = {
        "i-1": node(("argocd", "failed", "down")),
        "i-2": node(("argocd", "failed", "down")),
    }
    assert sk3s_status.disagreements(nodes) == []
