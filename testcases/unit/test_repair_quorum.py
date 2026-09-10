"""The quorum guard in ssm_repair_cluster.sh.

Removing an etcd member is irreversible and lowers the failures the cluster can
survive, so this guard is the last thing standing between a repair and a dead
control plane. It used to count Kubernetes NODES: members-after-removal was
(all nodes - stale) and "ready" was every Ready node. Agents and Karpenter
workers hold no etcd member, so both numbers were inflated by however many
happened to exist.

Observed live on sk3s-birch during a node-0 drill: one agent node made it print
"Ready nodes: 3" while only two etcd members were serving.

These tests extract the real bash functions and run them against fixture arrays,
rather than reimplementing the arithmetic in Python — a second implementation of
the thing under test proves nothing about the first.
"""

import pathlib
import re
import subprocess

import pytest

SCRIPT = (
    pathlib.Path(__file__).resolve().parents[2]
    / "examples"
    / "standard_deployment"
    / "scripts"
    / "ssm_repair_cluster.sh"
)

NEEDED = ("is_stale_node", "state_of_node", "quorum_is_safe")


def bash_functions():
    source = SCRIPT.read_text()
    out = []
    for name in NEEDED:
        match = re.search(rf"^function {name}\(\) \{{.*?^\}}", source, re.MULTILINE | re.DOTALL)
        assert match, f"{name} not found in {SCRIPT.name}"
        out.append(match.group(0))
    return "\n".join(out)


def quorum_is_safe(etcd, states, stale):
    """Run the script's own guard. Returns True if it permits the removal.

    `states` maps node name -> Ready/NotReady; `etcd` is the etcd membership;
    `stale` is what the repair intends to remove.
    """
    names = " ".join(f'"{n}"' for n in states)
    values = " ".join(f'"{s}"' for s in states.values())
    script = f"""
    set -uo pipefail
    C_RED=""; C_RST=""
    NODE_NAMES=({names})
    NODE_STATES=({values})
    ETCD_NODES=({" ".join(f'"{n}"' for n in etcd)})
    STALE_NODES=({" ".join(f'"{n}"' for n in stale)})
    {bash_functions()}
    quorum_is_safe
    """
    return subprocess.run(["bash", "-c", script], capture_output=True, timeout=60).returncode == 0


# ─── The live case ───────────────────────────────────────────────────────────


def test_the_observed_node0_drill_is_permitted():
    """3 etcd members, one terminated, two healthy survivors. Removal is correct."""
    assert quorum_is_safe(
        etcd=["ip-10-0-1-100", "ip-10-0-2-117", "ip-10-0-3-154"],
        states={
            "ip-10-0-1-100": "NotReady",
            "ip-10-0-1-224": "Ready",  # the agent node
            "ip-10-0-2-117": "Ready",
            "ip-10-0-3-154": "Ready",
        },
        stale=["ip-10-0-1-100"],
    )


# ─── The bug ─────────────────────────────────────────────────────────────────


def test_agents_do_not_prop_up_the_quorum_arithmetic():
    """THE REGRESSION. 3 etcd + 2 agents, one member stale and another NotReady.

    Removal leaves 2 members with only 1 Ready — no quorum. Counting all nodes
    computed 4 members / quorum 3 / ready 3 and allowed it.
    """
    assert not quorum_is_safe(
        etcd=["ip-10-0-1-100", "ip-10-0-2-117", "ip-10-0-3-154"],
        states={
            "ip-10-0-1-100": "NotReady",
            "ip-10-0-2-117": "NotReady",
            "ip-10-0-3-154": "Ready",
            "ip-10-0-1-224": "Ready",  # agent
            "ip-10-0-1-17": "Ready",  # Karpenter worker
        },
        stale=["ip-10-0-1-100"],
    )


@pytest.mark.parametrize("workers", [0, 1, 5, 20])
def test_the_verdict_does_not_change_with_the_number_of_workers(workers):
    """Adding non-etcd nodes must not move the answer in either direction."""
    states = {"ip-10-0-1-100": "NotReady", "ip-10-0-2-117": "NotReady", "ip-10-0-3-154": "Ready"}
    for n in range(workers):
        states[f"ip-10-0-9-{n}"] = "Ready"
    assert not quorum_is_safe(
        etcd=["ip-10-0-1-100", "ip-10-0-2-117", "ip-10-0-3-154"],
        states=states,
        stale=["ip-10-0-1-100"],
    )


# ─── Arithmetic ──────────────────────────────────────────────────────────────


def test_a_five_member_cluster_may_lose_two():
    etcd = [f"ip-10-0-0-{n}" for n in range(5)]
    states = dict.fromkeys(etcd, "Ready")
    states[etcd[0]] = states[etcd[1]] = "NotReady"
    assert quorum_is_safe(etcd=etcd, states=states, stale=etcd[:2])


def test_a_member_that_is_itself_being_removed_does_not_count_as_a_survivor():
    """It cannot vote afterwards, so it must not satisfy the quorum it leaves."""
    assert not quorum_is_safe(
        etcd=["a", "b", "c"],
        states={"a": "Ready", "b": "NotReady", "c": "NotReady"},
        stale=["a"],
    )


def test_a_not_ready_survivor_does_not_count():
    assert not quorum_is_safe(
        etcd=["a", "b", "c"], states={"a": "NotReady", "b": "NotReady", "c": "Ready"}, stale=["a"]
    )


def test_removing_nothing_from_a_healthy_cluster_is_permitted():
    assert quorum_is_safe(
        etcd=["a", "b", "c"], states={"a": "Ready", "b": "Ready", "c": "Ready"}, stale=[]
    )


# ─── Fail-safe ───────────────────────────────────────────────────────────────


def test_an_empty_membership_refuses_rather_than_permitting_everything():
    """No members found means the lookup failed, not that removal is free."""
    assert not quorum_is_safe(etcd=[], states={"a": "Ready"}, stale=["a"])


def test_removing_every_member_is_refused():
    assert not quorum_is_safe(
        etcd=["a", "b", "c"],
        states={"a": "NotReady", "b": "NotReady", "c": "NotReady"},
        stale=["a", "b", "c"],
    )


def test_a_node_missing_from_the_state_table_is_not_treated_as_ready():
    """Unknown is not Ready. Absence is never success (#110)."""
    assert not quorum_is_safe(etcd=["a", "b", "c"], states={"c": "Ready"}, stale=["a"])


# ─── The report's etcd figure ────────────────────────────────────────────────


def count_ready_etcd(etcd, states):
    """Run the script's own counter, the one the report prints."""
    source = SCRIPT.read_text()
    fns = "\n".join(
        re.search(rf"^function {n}\(\) \{{.*?^\}}", source, re.MULTILINE | re.DOTALL).group(0)
        for n in ("state_of_node", "count_ready_etcd")
    )
    script = f"""
    set -uo pipefail
    NODE_NAMES=({" ".join(f'"{n}"' for n in states)})
    NODE_STATES=({" ".join(f'"{s}"' for s in states.values())})
    ETCD_NODES=({" ".join(f'"{n}"' for n in etcd)})
    {fns}
    count_ready_etcd
    """
    done = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=60)
    return int(done.stdout.strip())


def test_the_report_counts_ready_etcd_members_not_ready_nodes():
    """The live cluster: 4 Ready nodes, 3 of them etcd members.

    Showing only the node count is what hid the miscount, so the report now
    carries the figure the guard actually decides on.
    """
    assert (
        count_ready_etcd(
            etcd=["ip-10-0-1-100", "ip-10-0-2-117", "ip-10-0-3-154"],
            states={
                "ip-10-0-1-100": "Ready",
                "ip-10-0-1-224": "Ready",  # agent
                "ip-10-0-2-117": "Ready",
                "ip-10-0-3-154": "Ready",
            },
        )
        == 3
    )


def test_a_not_ready_member_is_not_counted_by_the_report():
    assert (
        count_ready_etcd(etcd=["a", "b", "c"], states={"a": "NotReady", "b": "Ready", "c": "Ready"})
        == 2
    )
