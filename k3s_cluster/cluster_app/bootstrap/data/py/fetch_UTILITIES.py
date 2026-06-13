#!/usr/bin/env python3

# Builtin Modules
import subprocess
import shlex
import json
from dataclasses import dataclass

# This class + function is meant to help make SHELL commands easier to execute
@dataclass
class CommandResult:
    stdout:     str
    stderr:     str
    returncode: int

    @property
    def ok(self) -> bool:
        return self.returncode == 0

def run_command(cmd: str | list, timeout: int = 30) -> CommandResult:
    if isinstance(cmd, str):
        cmd = shlex.split(cmd)

    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return CommandResult(
            stdout=proc.stdout.strip(),
            stderr=proc.stderr.strip(),
            returncode=proc.returncode,
        )
    except FileNotFoundError:
        return CommandResult(stdout="", stderr=f"command not found: {cmd[0]}", returncode=-1)
    except subprocess.TimeoutExpired:
        return CommandResult(stdout="", stderr=f"command timed out after {timeout}s", returncode=-1)


# --- Kubernetes helpers (shared by the per-service fetch_*.py scripts) ---

KUBECTL = "kubectl"


def get_resources(resource: str, timeout: int = 20, kubectl: str = KUBECTL) -> dict:
    # Fetch a resource across all namespaces as parsed JSON. Returns an
    # "items: []" stub plus an "error" key when the call fails — notably when a
    # CRD isn't installed (e.g. the service was never deployed), so callers can
    # report that gracefully instead of crashing. --all-namespaces is harmless
    # for cluster-scoped kinds (ClusterSecretStore, EC2NodeClass, ...).
    result = run_command(f"{kubectl} get {resource} --all-namespaces -o json", timeout=timeout)
    if not result.ok:
        return {"items": [], "error": result.stderr or result.stdout}
    try:
        return json.loads(result.stdout) if result.stdout else {"items": []}
    except json.JSONDecodeError as exc:
        return {"items": [], "error": f"failed to parse json: {exc}"}


def get_ready_condition(obj: dict) -> dict:
    # Extract the standard status.conditions[type=Ready] entry shared by ESO,
    # Kyverno, and Karpenter CRDs. Returns a not-ready verdict when no such
    # condition exists yet (resource still reconciling, or never reported).
    for cond in obj.get("status", {}).get("conditions", []):
        if cond.get("type") == "Ready":
            return {
                "ready": cond.get("status") == "True",
                "reason": cond.get("reason", ""),
                "message": cond.get("message", ""),
            }
    return {
        "ready": False,
        "reason": "NoReadyCondition",
        "message": "no Ready condition present in status",
    }


def get_failing_conditions(obj: dict) -> list:
    # Surface every non-Ready sub-condition that isn't True — e.g. Karpenter's
    # SubnetsReady / SecurityGroupsReady / AMIsReady — so the exact reason a
    # resource is unhealthy is obvious without describing it by hand.
    failing = []
    for cond in obj.get("status", {}).get("conditions", []):
        if cond.get("type") == "Ready":
            continue
        if cond.get("status") != "True":
            failing.append({
                "type": cond.get("type", ""),
                "status": cond.get("status", ""),
                "reason": cond.get("reason", ""),
                "message": cond.get("message", ""),
            })
    return failing
