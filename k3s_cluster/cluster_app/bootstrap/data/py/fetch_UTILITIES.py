#!/usr/bin/env python3

# Builtin Modules
import json
import shlex
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass


def emit(output: dict, compact: bool | None = None) -> None:
    # Print a probe's result as JSON. The default is indented (human-readable)
    # so manual runs stay legible. Pass --compact (or compact=True) for compact
    # JSON: the E2E orchestrator batches every probe's stdout into one SSM
    # command, and SSM's get-command-invocation truncates StandardOutputContent
    # at ~24 KB — compact output keeps the batch under that limit so the trailing
    # probes' markers are not cut off.
    if compact is None:
        compact = "--compact" in sys.argv
    if compact:
        print(json.dumps(output, separators=(",", ":")))
    else:
        print(json.dumps(output, indent=4))


# This class + function is meant to help make SHELL commands easier to execute
@dataclass
class CommandResult:
    stdout: str
    stderr: str
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


# --- HTTP helper (shared by the in-cluster endpoint probes) ---


def http_get(url: str, timeout: int = 10, follow_redirects: bool = True) -> dict:
    # GET a URL and report {"status", "body", "error"}. Used by probes that must
    # check a Service's HTTP behaviour from a node (e.g. ArgoCD's /auth/login
    # redirect, Grafana /api/health) — signals that aren't visible via kubectl.
    # follow_redirects=False keeps the 3xx so callers can assert on it directly.
    handlers = []
    if not follow_redirects:

        class _NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None

        handlers.append(_NoRedirect())

    opener = urllib.request.build_opener(*handlers)
    try:
        resp = opener.open(url, timeout=timeout)
        body = resp.read(512).decode("utf-8", "replace")
        return {"status": resp.status, "body": body, "error": None}
    except urllib.error.HTTPError as exc:
        return {"status": exc.code, "body": "", "error": None}
    except Exception as exc:  # noqa: BLE001 - any transport failure is the signal
        return {"status": None, "body": "", "error": repr(exc)}


# --- Kubernetes helpers (shared by the per-service fetch_*.py scripts) ---

KUBECTL = "kubectl"


def get_resource(
    resource: str, namespace: str, name: str, timeout: int = 20, kubectl: str = KUBECTL
):
    # Fetch a single named resource as parsed JSON. Returns (obj_or_None, error).
    # Complements get_resources() (which lists across all namespaces) for the
    # probes that need one specific object (a Service's clusterIP, a CR's status).
    result = run_command(f"{kubectl} -n {namespace} get {resource} {name} -o json", timeout=timeout)
    if not result.ok:
        return None, result.stderr or result.stdout
    if not result.stdout:
        return None, "empty output"
    try:
        return json.loads(result.stdout), None
    except json.JSONDecodeError as exc:
        return None, f"failed to parse json: {exc}"


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


def get_pvcs(namespace: str, kubectl: str = KUBECTL) -> tuple:
    # List PersistentVolumeClaims in a namespace as normalized dicts
    # (name/phase/bound/storage_class/capacity/volume). Returns (pvcs, error);
    # error is non-None when the kubectl call failed. Shared by the per-component
    # storage probes (grafana/prometheus) so their collection logic can't drift.
    payload = get_resources("pvc", kubectl=kubectl)
    if "error" in payload:
        return [], payload["error"]
    pvcs = []
    for obj in payload.get("items", []):
        meta = obj.get("metadata", {})
        if meta.get("namespace") != namespace:
            continue
        spec = obj.get("spec", {})
        status = obj.get("status", {})
        phase = status.get("phase", "")
        pvcs.append(
            {
                "name": meta.get("name", ""),
                "phase": phase,
                "bound": phase == "Bound",
                "storage_class": spec.get("storageClassName"),
                "capacity": status.get("capacity", {}).get("storage"),
                "volume": spec.get("volumeName"),
            }
        )
    return pvcs, None


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
            failing.append(
                {
                    "type": cond.get("type", ""),
                    "status": cond.get("status", ""),
                    "reason": cond.get("reason", ""),
                    "message": cond.get("message", ""),
                }
            )
    return failing
