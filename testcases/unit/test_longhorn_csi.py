"""Longhorn CSI registration, and the grace a newly joined node gets.

Longhorn ships its CSI plugin as a DaemonSet, so a node that joined seconds ago
legitimately has no driver yet. Asserting registration with zero tolerance made
`sk3s status` fail for a minute or two on every Karpenter scale-up, on a
perfectly healthy cluster — observed live on sk3s-birch, where the offending
node was consolidated away as Underutilized minutes later.

The correction has to hold BOTH lines at once: a node still converging is not a
failure, and a node that has been up for ages without the driver is not a pass.
Most of this file pins the second.
"""

import datetime

import pytest
from sk3s_verify import registry
from sk3s_verify.checks import subsystems

NOW = datetime.datetime(2026, 9, 9, 22, 0, 0, tzinfo=datetime.timezone.utc)
DRIVER = subsystems.CSI_DRIVER


def node(name="ip-10-0-2-198", age_seconds=3600, created=..., deleting=False, cordoned=False):
    meta = {"name": name}
    if created is ...:
        stamp = NOW - datetime.timedelta(seconds=age_seconds)
        meta["creationTimestamp"] = stamp.isoformat().replace("+00:00", "Z")
    elif created is not None:
        meta["creationTimestamp"] = created
    if deleting:
        meta["deletionTimestamp"] = "2026-09-09T21:59:00Z"
    spec = {"unschedulable": True} if cordoned else {}
    return {"metadata": meta, "spec": spec}


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
        return [r for r, _ in self.entries]


# ─── Grace window configuration ──────────────────────────────────────────────


def test_grace_defaults_when_unset(monkeypatch):
    monkeypatch.delenv("LONGHORN_CSI_GRACE_SECONDS", raising=False)
    assert subsystems.csi_grace_seconds() == subsystems.DEFAULT_CSI_GRACE_SECONDS


def test_grace_reads_the_environment(monkeypatch):
    monkeypatch.setenv("LONGHORN_CSI_GRACE_SECONDS", "45")
    assert subsystems.csi_grace_seconds() == 45


@pytest.mark.parametrize("value", ["0", "-5", "abc", "5.5", " "])
def test_a_malformed_grace_is_rejected_not_defaulted(monkeypatch, value):
    """#110: a bad value that silently defaults hides that the knob did nothing."""
    monkeypatch.setenv("LONGHORN_CSI_GRACE_SECONDS", value)
    with pytest.raises(ValueError):
        subsystems.csi_grace_seconds()


# ─── node_age ────────────────────────────────────────────────────────────────


def test_node_age_measures_from_the_creation_timestamp():
    assert subsystems.node_age(node(age_seconds=120), NOW) == 120


@pytest.mark.parametrize("created", [None, "not-a-timestamp", ""])
def test_node_age_is_unusable_when_it_cannot_be_read(created):
    """Absent and unreadable are collapsed HERE on purpose.

    They mean different things elsewhere, but for grace they mean the same
    thing: the node cannot be shown to be young, so it does not get excused.
    csi_verdict tests the consequence; this pins that neither returns a number.
    """
    assert not isinstance(subsystems.node_age(node(created=created), NOW), float)


# ─── departing ───────────────────────────────────────────────────────────────


def test_a_node_being_deleted_is_departing():
    assert subsystems.departing(node(deleting=True)) is True


def test_a_cordoned_node_is_departing():
    """Karpenter cordons before it drains."""
    assert subsystems.departing(node(cordoned=True)) is True


def test_an_ordinary_node_is_not_departing():
    assert subsystems.departing(node()) is False


# ─── csi_verdict: registration wins outright ─────────────────────────────────


def test_a_registered_node_passes():
    result, message = subsystems.csi_verdict(node(), [DRIVER], 300, NOW)
    assert result == registry.PASSED
    assert "registered" in message


def test_a_registered_node_passes_even_while_young():
    result, _ = subsystems.csi_verdict(node(age_seconds=5), [DRIVER], 300, NOW)
    assert result == registry.PASSED


def test_a_registered_node_passes_even_while_departing():
    result, _ = subsystems.csi_verdict(node(deleting=True), [DRIVER], 300, NOW)
    assert result == registry.PASSED


# ─── csi_verdict: the failure that must survive ──────────────────────────────


def test_an_old_unregistered_node_fails():
    """It cannot mount a Longhorn volume. That is worth blocking on."""
    result, message = subsystems.csi_verdict(node(age_seconds=3600), [], 300, NOW)
    assert result == registry.FAILED
    assert "not registered" in message


def test_a_node_exactly_at_the_grace_boundary_fails():
    """The window is closed at its edge, so 'grace expired' has one meaning."""
    result, _ = subsystems.csi_verdict(node(age_seconds=300), [], 300, NOW)
    assert result == registry.FAILED


def test_an_unregistered_node_with_no_timestamp_fails():
    """Grace requires PROOF of youth; absence of proof is not youth."""
    result, _ = subsystems.csi_verdict(node(created=None), [], 300, NOW)
    assert result == registry.FAILED


def test_an_unregistered_node_with_an_unreadable_timestamp_fails():
    """Otherwise the one node with broken metadata gets a permanent pass."""
    result, _ = subsystems.csi_verdict(node(created="garbage"), [], 300, NOW)
    assert result == registry.FAILED


def test_other_drivers_do_not_satisfy_the_check():
    result, _ = subsystems.csi_verdict(node(), ["ebs.csi.aws.com"], 300, NOW)
    assert result == registry.FAILED


# ─── csi_verdict: the grace itself ───────────────────────────────────────────


def test_a_young_unregistered_node_is_skipped_never_passed():
    result, message = subsystems.csi_verdict(node(age_seconds=45), [], 300, NOW)
    assert result == registry.SKIPPED
    assert "45s ago" in message
    assert "300s grace" in message


def test_a_departing_unregistered_node_is_skipped():
    result, message = subsystems.csi_verdict(node(deleting=True, age_seconds=3600), [], 300, NOW)
    assert result == registry.SKIPPED
    assert "draining or cordoned" in message


# ─── node_drivers ────────────────────────────────────────────────────────────


def test_a_missing_csinode_object_reads_as_no_drivers(monkeypatch):
    """Created alongside the node, so a brand-new node can 404 here."""

    def not_found(args, timeout=30):
        raise subsystems.kube.Unavailable('csinodes.storage.k8s.io "x" not found')

    monkeypatch.setattr(subsystems.kube, "run_json", not_found)
    assert subsystems.node_drivers("x") == []


def test_any_other_query_failure_still_propagates(monkeypatch):
    """A query we could not run is not an empty answer (#156)."""

    def refused(args, timeout=30):
        raise subsystems.kube.Unavailable("connection refused")

    monkeypatch.setattr(subsystems.kube, "run_json", refused)
    with pytest.raises(subsystems.kube.Unavailable):
        subsystems.node_drivers("x")


# ─── The live incident, as a regression test ─────────────────────────────────


def wire(monkeypatch, nodes, drivers_by_node):
    monkeypatch.setattr(subsystems.kube, "exists", lambda args, timeout=30: True)
    monkeypatch.setattr(
        subsystems.workloads, "state", lambda kind, ns, name: (True, f"{ns}/{name} ready")
    )

    def run_json(args, timeout=30):
        if "nodes" in args:
            return {"items": nodes}
        return {"spec": {"drivers": [{"name": d} for d in drivers_by_node[args[-1]]]}}

    monkeypatch.setattr(subsystems.kube, "run_json", run_json)


def test_a_karpenter_scale_up_no_longer_fails_a_healthy_cluster(monkeypatch):
    """sk3s-birch, 2026-09-09: three healthy control planes plus one Karpenter
    node 60s old. Reported FAIL 0/3; the node was consolidated away minutes
    later as Underutilized."""
    nodes = [node(name=f"cp-{n}", age_seconds=7200) for n in range(3)] + [
        node(name="ip-10-0-2-198", age_seconds=60)
    ]
    drivers = {f"cp-{n}": [DRIVER] for n in range(3)}
    drivers["ip-10-0-2-198"] = []
    wire(monkeypatch, nodes, drivers)

    rec = Recorder()
    subsystems.longhorn(rec, now=NOW)
    assert rec.results.count("failed") == 0
    assert rec.results.count("skipped") == 1


def test_a_node_broken_for_an_hour_still_fails(monkeypatch):
    """The grace must not have quietly disabled the check."""
    nodes = [node(name="cp-0", age_seconds=7200), node(name="broken", age_seconds=7200)]
    wire(monkeypatch, nodes, {"cp-0": [DRIVER], "broken": []})

    rec = Recorder()
    subsystems.longhorn(rec, now=NOW)
    assert rec.results.count("failed") == 1


def test_a_fully_healthy_cluster_passes_every_node(monkeypatch):
    nodes = [node(name=f"cp-{n}", age_seconds=7200) for n in range(3)]
    wire(monkeypatch, nodes, {f"cp-{n}": [DRIVER] for n in range(3)})

    rec = Recorder()
    subsystems.longhorn(rec, now=NOW)
    assert rec.results.count("failed") == 0
    assert rec.results.count("skipped") == 0
