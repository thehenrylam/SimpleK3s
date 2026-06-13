#!/usr/bin/env python3

# Builtin Modules
import importlib.util
import os
import json

_dir = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "fetch_UTILITIES",
    os.path.join(_dir, "fetch_UTILITIES.py")
)
_utils = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_utils)
run_command = _utils.run_command

KUBECTL = "kubectl"


def _raw_endpoint(endpoint: str, timeout: int = 10) -> dict:
    result = run_command(f"{KUBECTL} get --raw='{endpoint}'", timeout=timeout)
    # kubectl exits non-zero when the endpoint returns a non-2xx status,
    # but the body is still useful — prefer stdout, fall back to stderr.
    response = result.stdout or result.stderr
    return {
        "ok": result.ok and response.strip() == "ok",
        "response": response
    }


def _parse_verbose_checks(output: str) -> dict:
    # Parses lines like "[+]ping ok" or "[-]etcd failed: ..."
    checks = {}
    for line in output.splitlines():
        line = line.strip()
        if line.startswith("[+]"):
            name = line[3:].split()[0]
            checks[name] = True
        elif line.startswith("[-]"):
            name = line[3:].split()[0]
            checks[name] = False
    return checks


# Check: API server is alive and not broken
def fetch_stable() -> dict:
    healthz = _raw_endpoint("/healthz")

    livez = _raw_endpoint("/livez")
    livez_verbose = run_command(f"{KUBECTL} get --raw='/livez?verbose'", timeout=10)
    livez_checks = _parse_verbose_checks(livez_verbose.stdout or livez_verbose.stderr)

    return {
        "healthz": healthz,
        "livez": {
            **livez,
            "checks": livez_checks
        }
    }


# Check: API server is ready to serve requests + control plane components are up
def fetch_ready() -> dict:
    readyz = _raw_endpoint("/readyz")
    readyz_verbose = run_command(f"{KUBECTL} get --raw='/readyz?verbose'", timeout=10)
    readyz_checks = _parse_verbose_checks(readyz_verbose.stdout or readyz_verbose.stderr)

    # Scheduler and controller-manager heartbeat via kube-system leases
    lease_result = run_command(
        f"{KUBECTL} get lease -n kube-system kube-scheduler kube-controller-manager --no-headers",
        timeout=10
    )
    scheduler_ok = False
    controller_manager_ok = False
    if lease_result.ok:
        for line in lease_result.stdout.splitlines():
            parts = line.split()
            if not parts:
                continue
            if parts[0] == "kube-scheduler":
                scheduler_ok = True
            elif parts[0] == "kube-controller-manager":
                controller_manager_ok = True

    return {
        "readyz": {
            **readyz,
            "checks": readyz_checks
        },
        "scheduler": {"ok": scheduler_ok},
        "controller_manager": {"ok": controller_manager_ok}
    }


# Check: nodes are present and ready, system pods are running, expected namespaces exist
def fetch_platform() -> dict:
    # --- Nodes ---
    node_result = run_command(f"{KUBECTL} get nodes --no-headers", timeout=15)
    nodes_total = 0
    nodes_ready = 0
    nodes_not_ready = 0
    if node_result.ok:
        lines = [ln for ln in node_result.stdout.splitlines() if ln.strip()]
        nodes_total = len(lines)
        for line in lines:
            parts = line.split()
            # STATUS column: "Ready" or "NotReady" (possibly "Ready,SchedulingDisabled")
            status = parts[1] if len(parts) >= 2 else ""
            if "Ready" in status and "NotReady" not in status:
                nodes_ready += 1
            else:
                nodes_not_ready += 1

    # --- kube-system pods ---
    # Classify by .status.phase. Succeeded pods are completed Jobs/CronJobs
    # (helm-install-*, descheduler-*) — a normal terminal state, NOT a failure —
    # so they get their own "completed" bucket instead of inflating "not_running".
    # This mirrors how fetch_k3s-apps.py skips Succeeded pods. The text STATUS
    # column conflates "Completed" with failures, so we parse JSON phases.
    pod_result = run_command(f"{KUBECTL} get pods -n kube-system -o json", timeout=15)
    pods_total = 0
    pods_running = 0
    pods_completed = 0
    pods_not_running = 0
    if pod_result.ok:
        try:
            pod_items = json.loads(pod_result.stdout).get("items", []) if pod_result.stdout else []
        except json.JSONDecodeError:
            pod_items = []
        pods_total = len(pod_items)
        for pod in pod_items:
            phase = pod.get("status", {}).get("phase", "")
            if phase == "Running":
                pods_running += 1
            elif phase == "Succeeded":
                pods_completed += 1
            else:
                # Pending / Failed / Unknown — genuinely not running.
                pods_not_running += 1

    # --- Namespaces ---
    ns_result = run_command(f"{KUBECTL} get namespaces --no-headers", timeout=10)
    namespaces = []
    if ns_result.ok:
        for line in ns_result.stdout.splitlines():
            parts = line.split()
            if parts:
                namespaces.append(parts[0])

    return {
        "nodes": {
            "total": nodes_total,
            "ready": nodes_ready,
            "not_ready": nodes_not_ready
        },
        "system_pods": {
            "total": pods_total,
            "running": pods_running,
            "completed": pods_completed,
            "not_running": pods_not_running
        },
        "namespaces": namespaces
    }


def fetch_k8s_platform() -> dict:
    return {
        "stable": fetch_stable(),
        "ready": fetch_ready(),
        "platform": fetch_platform()
    }


if __name__ == "__main__":
    output = fetch_k8s_platform()
    print(json.dumps(output, indent=4))
