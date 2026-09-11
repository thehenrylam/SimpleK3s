"""Terminate this cluster's Karpenter-provisioned nodes on cluster destroy (#128).

Invoked by Terraform (aws_lambda_invocation, lifecycle_scope = "CRUD"), which
fires on create and update as well as delete; only delete does work.

Karpenter's nodes are created in-cluster, so they never enter Terraform state and
nothing else reaps them. Their ENIs then block the security group and VPC delete.

Timing is the whole problem -- reaping while Karpenter can still see Pending pods
just makes it replace whatever is killed -- but the ordering is handled in
Terraform: karpenter_reap_lambda.tf puts this after the cluster's instances and
before their security group, and instance destroy does not return until the
instance is 'terminated'. So by the time this runs, Karpenter is already gone.
"""

import logging
import os
import time

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Set on Karpenter nodes by cluster_app/karpenter/data/karpenter-nodeclass.yaml.tmpl.
# Terraform-managed nodes carry Nickname but not this, so requiring both is what
# stops the reap reaching a control-plane node.
LIFECYCLE_TAG = "simplek3s.io/lifecycle"
LIFECYCLE_VALUE = "karpenter"

# Two lists, because "could Karpenter still act?" and "does this node still need
# killing?" are different questions. Conflating them cost a live teardown.
PROVISIONING_STATES = ["pending", "running"]  # cluster node could still run Karpenter
REAPABLE_STATES = ["pending", "running", "stopping", "stopped"]  # not yet dying

# Long enough for EC2 to register the terminate and start the transition.
KILL_CONFIRM_SECONDS = 15
KILL_ROUNDS = 3

_sleep = time.sleep


def _ec2_client(region):
    # Imported here so the module loads without boto3, which the unit tests rely on.
    import boto3

    return boto3.client("ec2", region_name=region)


def _instances(ec2, filters):
    found = []
    for page in ec2.get_paginator("describe_instances").paginate(Filters=filters):
        for reservation in page.get("Reservations", []):
            found.extend(reservation.get("Instances", []))
    return found


def _is_karpenter(instance):
    return any(
        tag.get("Key") == LIFECYCLE_TAG and tag.get("Value") == LIFECYCLE_VALUE
        for tag in instance.get("Tags", [])
    )


def _cluster_nodes(ec2, nickname, states):
    """This cluster's Terraform-managed nodes. EC2 cannot filter on tag absence."""
    found = _instances(
        ec2,
        [
            {"Name": "tag:Nickname", "Values": [nickname]},
            {"Name": "instance-state-name", "Values": states},
        ],
    )
    return sorted(i["InstanceId"] for i in found if not _is_karpenter(i))


def _karpenter_nodes(ec2, nickname, states):
    found = _instances(
        ec2,
        [
            {"Name": "tag:Nickname", "Values": [nickname]},
            {"Name": f"tag:{LIFECYCLE_TAG}", "Values": [LIFECYCLE_VALUE]},
            {"Name": "instance-state-name", "Values": states},
        ],
    )
    return sorted(i["InstanceId"] for i in found)


def _assert_cluster_is_down(ec2, nickname):
    """Refuse to reap while a cluster node could still be running Karpenter.

    Terraform's ordering should make this impossible. It is asserted rather than
    assumed because if the ordering ever regresses, reaping here is what makes
    Karpenter provision a replacement that outlives the teardown -- a failure that
    shows up much later as an unrelated VPC error.
    """
    alive = _cluster_nodes(ec2, nickname, PROVISIONING_STATES)
    if alive:
        raise RuntimeError(
            f"Karpenter reap refused: cluster '{nickname}' still has {len(alive)} "
            f"node(s) running ({', '.join(alive)}). Nothing was terminated. This "
            "should be impossible -- the reap is ordered after the cluster's "
            "instances -- so check the depends_on wiring in karpenter_reap_lambda.tf."
        )


def _reap(ec2, nickname):
    """Terminate Karpenter nodes, re-issuing until they are all dying.

    Returns once every node is shutting-down; Terraform retries the dependent
    security-group delete meanwhile, so there is no need to wait for 'terminated'.
    """
    targets = _karpenter_nodes(ec2, nickname, REAPABLE_STATES)
    if not targets:
        return []

    logger.info("Reaping %d Karpenter node(s): %s", len(targets), ", ".join(targets))
    for _round in range(KILL_ROUNDS):
        try:
            ec2.terminate_instances(InstanceIds=targets)
        except Exception as exc:
            raise RuntimeError(
                f"Karpenter reap could not terminate {targets} for '{nickname}': "
                f"{exc}. Terminate them by hand and re-run the destroy. If this is "
                "an authorization error, the role's TerminateInstances permission "
                f"is conditioned on Nickname={nickname} and "
                f"{LIFECYCLE_TAG}={LIFECYCLE_VALUE}."
            ) from exc

        _sleep(KILL_CONFIRM_SECONDS)
        stubborn = _karpenter_nodes(ec2, nickname, REAPABLE_STATES)
        if not stubborn:
            return targets
        targets = stubborn

    raise RuntimeError(
        f"Karpenter nodes {targets} for '{nickname}' did not start terminating "
        f"after {KILL_ROUNDS} attempts. They still hold ENIs, so the VPC delete "
        "will fail. Terminate them by hand and re-run the destroy."
    )


def handler(event, _context):
    # Fail closed: CRUD fires on create/update too, and a console test sends no tf key.
    action = event.get("tf", {}).get("action")
    if action != "delete":
        logger.info("action=%s is not a delete; skipping reap", action)
        return {"skipped": action}

    nickname = (event.get("nickname") or "").strip()
    if not nickname:
        raise ValueError(
            "Karpenter reap aborted: no 'nickname' in the payload, so the tag "
            "filter would be unscoped and could match another cluster's nodes."
        )

    ec2 = _ec2_client(event.get("region") or os.environ.get("AWS_REGION"))
    _assert_cluster_is_down(ec2, nickname)
    reaped = _reap(ec2, nickname)

    logger.info("Reaped %d Karpenter node(s)", len(reaped))
    return {"nickname": nickname, "terminated": reaped}
