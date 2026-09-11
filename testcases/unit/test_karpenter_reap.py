"""The destroy-time Karpenter node reaper (#128).

Two things are worth testing here. The guard, because Terraform invokes this on
create and update as well as delete, and a mistake reaps a live cluster's
capacity. And the wait, because reaping before the control plane is down makes
Karpenter replace whatever was killed.
"""

import pytest
import reap_karpenter_nodes as reap

KARPENTER_TAG = {"Key": reap.LIFECYCLE_TAG, "Value": reap.LIFECYCLE_VALUE}
DELETE = {"tf": {"action": "delete"}, "nickname": "sk3s-birch", "region": "us-east-1"}


def karpenter(instance_id):
    return {"InstanceId": instance_id, "Tags": [KARPENTER_TAG]}


def cluster_node(instance_id):
    return {"InstanceId": instance_id, "Tags": [{"Key": "Nickname", "Value": "sk3s-birch"}]}


class FakeEC2:
    """Serves scripted sweeps, told apart by whether the filter names the tag."""

    def __init__(self, cluster_sweeps=None, karpenter_sweeps=None, terminate_fails=False):
        self._cluster = list(cluster_sweeps) if cluster_sweeps is not None else [[]]
        self._karpenter = list(karpenter_sweeps) if karpenter_sweeps is not None else [[]]
        self.filters_used = []
        self.terminated = []
        self._terminate_fails = terminate_fails

    @staticmethod
    def _pop(sweeps):
        return sweeps.pop(0) if len(sweeps) > 1 else (sweeps[0] if sweeps else [])

    def get_paginator(self, _name):
        return self

    def paginate(self, Filters):  # noqa: N803 - boto3's casing
        self.filters_used.append(Filters)
        tagged = any(f["Name"] == f"tag:{reap.LIFECYCLE_TAG}" for f in Filters)
        found = self._pop(self._karpenter if tagged else self._cluster)
        return [{"Reservations": [{"Instances": found}]}]

    def terminate_instances(self, InstanceIds):  # noqa: N803 - boto3's casing
        if self._terminate_fails:
            raise RuntimeError("UnauthorizedOperation")
        self.terminated.append(InstanceIds)


@pytest.fixture
def fake_ec2(monkeypatch):
    """Fake client, with sleeps made instant."""
    monkeypatch.setattr(reap, "_sleep", lambda _s: None)

    def _install(**kwargs):
        client = FakeEC2(**kwargs)
        monkeypatch.setattr(reap, "_ec2_client", lambda region: client)
        return client

    return _install


def states_for(client, tagged):
    """The instance-state filter used by the tagged (reap) or untagged (wait) query."""
    for filters in client.filters_used:
        if any(f["Name"] == f"tag:{reap.LIFECYCLE_TAG}" for f in filters) == tagged:
            return {f["Name"]: f["Values"] for f in filters}["instance-state-name"]
    raise AssertionError("query never ran")


# --- Guard ------------------------------------------------------------------


@pytest.mark.parametrize("action", ["create", "update"])
def test_non_delete_actions_never_touch_ec2(action, monkeypatch):
    monkeypatch.setattr(reap, "_ec2_client", lambda _r: pytest.fail(f"{action} must not reach EC2"))
    assert reap.handler({"tf": {"action": action}, "nickname": "x"}, None) == {"skipped": action}


def test_a_missing_tf_key_fails_closed(monkeypatch):
    monkeypatch.setattr(reap, "_ec2_client", lambda _r: pytest.fail("must not reach EC2"))
    assert reap.handler({"nickname": "sk3s-birch"}, None) == {"skipped": None}


def test_a_blank_nickname_is_refused(fake_ec2):
    fake_ec2()
    with pytest.raises(ValueError, match="unscoped"):
        reap.handler({"tf": {"action": "delete"}, "nickname": "   "}, None)


# --- The cluster-is-down assertion ------------------------------------------
# Terraform's ordering should make a live cluster impossible here. It is asserted
# anyway, because if that ordering regresses the reap makes Karpenter replace what
# it kills, and the damage only surfaces later as an unrelated VPC error.


def test_nothing_is_reaped_while_a_cluster_node_still_runs(fake_ec2):
    client = fake_ec2(
        cluster_sweeps=[[cluster_node("i-cp1")]],
        karpenter_sweeps=[[karpenter("i-worker")]],
    )
    with pytest.raises(RuntimeError, match="still has 1 node"):
        reap.handler(DELETE, None)
    assert client.terminated == []


def test_the_refusal_points_at_the_ordering(fake_ec2):
    """The operator needs to know this is a wiring bug, not a transient state."""
    fake_ec2(cluster_sweeps=[[cluster_node("i-cp1")]])
    with pytest.raises(RuntimeError, match="depends_on"):
        reap.handler(DELETE, None)


def test_a_shutting_down_node_does_not_block_the_reap(fake_ec2):
    """Its API server is going, so Karpenter cannot provision against it."""
    client = fake_ec2()
    reap.handler(DELETE, None)
    assert states_for(client, tagged=False) == reap.PROVISIONING_STATES
    assert "shutting-down" not in states_for(client, tagged=False)


def test_an_agent_node_blocks_the_reap_too(fake_ec2):
    """Karpenter is a Deployment; it need not be on a control-plane node."""
    client = fake_ec2(cluster_sweeps=[[cluster_node("i-agent")]])
    with pytest.raises(RuntimeError):
        reap.handler(DELETE, None)
    assert client.terminated == []


def test_karpenter_nodes_are_not_counted_as_cluster_nodes(fake_ec2):
    """Otherwise the nodes to reap would block their own reaping."""
    client = fake_ec2(
        cluster_sweeps=[[karpenter("i-worker")]],
        karpenter_sweeps=[[karpenter("i-worker")], []],
    )
    reap.handler(DELETE, None)
    assert client.terminated == [["i-worker"]]


# --- Reaping ----------------------------------------------------------------


def test_no_karpenter_nodes_is_a_clean_no_op(fake_ec2):
    client = fake_ec2()
    assert reap.handler(DELETE, None)["terminated"] == []
    assert client.terminated == []


def test_the_reap_is_scoped_to_this_cluster_and_to_karpenter(fake_ec2):
    client = fake_ec2(karpenter_sweeps=[[karpenter("i-1")], []])
    reap.handler(DELETE, None)
    tagged = [
        f for f in client.filters_used if any(x["Name"].endswith(reap.LIFECYCLE_TAG) for x in f)
    ]
    by_name = {f["Name"]: f["Values"] for f in tagged[0]}
    assert by_name["tag:Nickname"] == ["sk3s-birch"]
    assert by_name[f"tag:{reap.LIFECYCLE_TAG}"] == [reap.LIFECYCLE_VALUE]


def test_a_stopped_node_is_still_reaped(fake_ec2):
    """It holds an ENI, so it blocks the VPC delete like any other."""
    client = fake_ec2()
    reap.handler(DELETE, None)
    assert "stopped" in states_for(client, tagged=True)


def test_the_kill_order_is_reissued_until_the_nodes_are_dying(fake_ec2):
    client = fake_ec2(karpenter_sweeps=[[karpenter("i-1")], [karpenter("i-1")], []])
    reap.handler(DELETE, None)
    assert client.terminated == [["i-1"], ["i-1"]]


def test_nodes_that_never_start_dying_fail_loudly(fake_ec2):
    fake_ec2(karpenter_sweeps=[[karpenter("i-1")]])
    with pytest.raises(RuntimeError, match="did not start terminating"):
        reap.handler(DELETE, None)


def test_a_failed_terminate_names_the_tag_condition(fake_ec2):
    fake_ec2(karpenter_sweeps=[[karpenter("i-1")], []], terminate_fails=True)
    with pytest.raises(RuntimeError, match="simplek3s.io/lifecycle=karpenter"):
        reap.handler(DELETE, None)


def test_the_two_state_lists_stay_distinct():
    """If they collapse into one, either the wait or the reap becomes wrong."""
    assert reap.PROVISIONING_STATES != reap.REAPABLE_STATES
    assert set(reap.PROVISIONING_STATES) < set(reap.REAPABLE_STATES)
