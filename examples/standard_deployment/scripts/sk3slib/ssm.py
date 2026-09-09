"""AWS discovery and SSM execution.

Shells out to the `aws` CLI for the same reason scripts/common.sh does: it is
already a hard requirement of this deployment, so using it keeps the critical
path free of an interpreter environment that would itself need repairing.
"""

import json
import subprocess
import time

# SSM caps what GetCommandInvocation returns and cuts mid-stream. A truncated
# payload must be reported, never silently treated as the whole answer.
STDOUT_LIMIT = 24000
STDERR_LIMIT = 8000
TRUNCATION_MARKER = "--output truncated--"

TERMINAL = ("Success", "Failed", "Cancelled", "TimedOut", "Undeliverable", "Terminated")


class AwsError(RuntimeError):
    pass


def aws(args, profile, region, parse=True, timeout=120):
    cmd = ["aws", *args, "--profile", profile, "--region", region]
    if parse:
        cmd += ["--output", "json"]
    proc = subprocess.run(cmd, capture_output=True, timeout=timeout)
    if proc.returncode != 0:
        detail = proc.stderr.decode(errors="replace").strip().splitlines()
        raise AwsError(detail[-1] if detail else f"aws exited {proc.returncode}")
    out = proc.stdout.decode(errors="replace")
    if not parse:
        return out
    return json.loads(out) if out.strip() else {}


def _role_from_name(name):
    """Classify by Name tag, the same rule ssm_pick_instance.py applies, so the
    tools can never disagree about what a node is."""
    lowered = (name or "").lower()
    if "controlplane" in lowered or "control-plane" in lowered:
        return "control-plane"
    if "agentplane" in lowered or "agent-plane" in lowered:
        return "agent"
    if "karpenter" in lowered:
        return "karpenter"
    return "node"


def cluster_instances(profile, region, nickname, scope="controlplane"):
    """Running instances for a cluster, sorted by instance id.

    SORTED because selection has to be reproducible: EC2 returns instances in no
    guaranteed order, and taking "the first" from an unsorted list is how the
    same command came to act on different nodes on different days (#144).
    """
    payload = aws(
        [
            "ec2",
            "describe-instances",
            "--filters",
            f"Name=tag:Nickname,Values={nickname}",
            "Name=instance-state-name,Values=running",
        ],
        profile,
        region,
    )
    found = []
    for reservation in payload.get("Reservations", []):
        for inst in reservation.get("Instances", []):
            name = next((t["Value"] for t in inst.get("Tags", []) if t.get("Key") == "Name"), "")
            role = _role_from_name(name)
            if scope == "controlplane" and role != "control-plane":
                continue
            found.append({"id": inst["InstanceId"], "name": name, "role": role})
    return sorted(found, key=lambda i: i["id"])


def unreachable(profile, region, instance_ids):
    """Instances SSM cannot dispatch to right now, as {id: status}.

    An instance SSM has never heard of reports "unknown" and counts as
    unreachable: absence of a ping record is not evidence of health.
    """
    payload = aws(["ssm", "describe-instance-information"], profile, region)
    known = {
        i["InstanceId"]: i.get("PingStatus", "unknown")
        for i in payload.get("InstanceInformationList", [])
    }
    return {i: known.get(i, "unknown") for i in instance_ids if known.get(i) != "Online"}


def send_command(profile, region, instance_ids, command, comment="sk3s"):
    payload = aws(
        [
            "ssm",
            "send-command",
            "--instance-ids",
            *instance_ids,
            "--document-name",
            "AWS-RunShellScript",
            "--comment",
            comment[:100],
            "--parameters",
            json.dumps({"commands": [command]}),
        ],
        profile,
        region,
    )
    return payload["Command"]["CommandId"]


def truncated(text, limit):
    return text.endswith(TRUNCATION_MARKER) or len(text) >= limit


def await_all(profile, region, command_id, instance_ids, max_polls=180, interval=5, on_tick=None):
    """Poll until every invocation reaches a terminal state.

    Returns {instance_id: {status, stdout, stderr, truncated}}. An invocation
    that never reached a terminal state is reported as status "Pending" rather
    than being dropped — a node we stopped waiting for has not passed.
    """
    results = {i: None for i in instance_ids}
    for tick in range(max_polls):
        pending = [i for i, r in results.items() if r is None]
        if not pending:
            break
        for instance_id in pending:
            try:
                inv = aws(
                    [
                        "ssm",
                        "get-command-invocation",
                        "--command-id",
                        command_id,
                        "--instance-id",
                        instance_id,
                    ],
                    profile,
                    region,
                )
            except AwsError:
                continue  # not visible yet
            status = inv.get("Status", "")
            if status in TERMINAL:
                stdout = inv.get("StandardOutputContent", "")
                stderr = inv.get("StandardErrorContent", "")
                results[instance_id] = {
                    "status": status,
                    "stdout": stdout,
                    "stderr": stderr,
                    "truncated": truncated(stdout, STDOUT_LIMIT),
                }
        if on_tick:
            on_tick(tick + 1, max_polls, [i for i, r in results.items() if r is None])
        if any(r is None for r in results.values()):
            time.sleep(interval)

    for instance_id, result in results.items():
        if result is None:
            results[instance_id] = {
                "status": "Pending",
                "stdout": "",
                "stderr": "",
                "truncated": False,
            }
    return results
