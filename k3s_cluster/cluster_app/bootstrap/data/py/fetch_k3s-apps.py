#!/usr/bin/env python3

# Builtin Modules
import argparse
import importlib.util
import os
import json
import time
import sys

_dir = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "fetch_UTILITIES",
    os.path.join(_dir, "fetch_UTILITIES.py")
)
_utils = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_utils)
run_command = _utils.run_command

KUBECTL = "kubectl"

# Workload kinds we treat as "apps". These are vanilla Kubernetes primitives,
# so the checks stay portable across K3s, EKS, vanilla K8s, etc. Every helm
# chart / manifest we deploy ultimately produces one of these — so we discover
# apps dynamically instead of hardcoding names like "traefik" or "argocd".
WORKLOAD_KINDS = ["deployments", "statefulsets", "daemonsets"]

# Pod container "waiting" reasons that are a normal part of startup. Anything
# else (CrashLoopBackOff, ImagePullBackOff, CreateContainerError, ...) is
# treated as unhealthy. Using an allow-list keeps us forward compatible: new
# error reasons are flagged automatically without code changes.
TRANSIENT_WAITING_REASONS = {"ContainerCreating", "PodInitializing"}


def _get_json(resource: str, timeout: int = 20) -> dict:
    # Query a resource across all namespaces as JSON. Returns the parsed object,
    # or an "items: []" stub plus an error string when the call/parse fails.
    result = run_command(f"{KUBECTL} get {resource} --all-namespaces -o json", timeout=timeout)
    if not result.ok:
        return {"items": [], "error": result.stderr or result.stdout}
    try:
        return json.loads(result.stdout) if result.stdout else {"items": []}
    except json.JSONDecodeError as exc:
        return {"items": [], "error": f"failed to parse json: {exc}"}


def _spec_replicas(obj: dict) -> int:
    # spec.replicas defaults to 1 when omitted (matches Kubernetes behavior).
    replicas = obj.get("spec", {}).get("replicas")
    return 1 if replicas is None else replicas


def _generation_synced(obj: dict) -> bool:
    # The controller has observed the latest spec when observedGeneration has
    # caught up to metadata.generation. Until then, status counts are stale.
    generation = obj.get("metadata", {}).get("generation", 0)
    observed = obj.get("status", {}).get("observedGeneration", 0)
    return observed >= generation


def _eval_deployment(obj: dict) -> dict:
    status = obj.get("status", {})
    desired = _spec_replicas(obj)
    available = status.get("availableReplicas", 0)
    updated = status.get("updatedReplicas", 0)
    ready = (
        _generation_synced(obj)
        and updated == desired
        and available == desired
    )
    return {
        "desired": desired,
        "ready_replicas": status.get("readyReplicas", 0),
        "available": available,
        "updated": updated,
        "ready": ready,
    }


def _eval_statefulset(obj: dict) -> dict:
    status = obj.get("status", {})
    desired = _spec_replicas(obj)
    ready_replicas = status.get("readyReplicas", 0)
    updated = status.get("updatedReplicas", 0)
    # currentRevision == updateRevision means the rollout has fully converged.
    rollout_done = status.get("currentRevision") == status.get("updateRevision")
    ready = (
        _generation_synced(obj)
        and ready_replicas == desired
        and updated == desired
        and rollout_done
    )
    return {
        "desired": desired,
        "ready_replicas": ready_replicas,
        "available": ready_replicas,
        "updated": updated,
        "ready": ready,
    }


def _eval_daemonset(obj: dict) -> dict:
    status = obj.get("status", {})
    desired = status.get("desiredNumberScheduled", 0)
    number_ready = status.get("numberReady", 0)
    updated = status.get("updatedNumberScheduled", 0)
    available = status.get("numberAvailable", 0)
    ready = (
        _generation_synced(obj)
        and number_ready == desired
        and updated == desired
        and available == desired
    )
    return {
        "desired": desired,
        "ready_replicas": number_ready,
        "available": available,
        "updated": updated,
        "ready": ready,
    }


_EVALUATORS = {
    "Deployment": _eval_deployment,
    "StatefulSet": _eval_statefulset,
    "DaemonSet": _eval_daemonset,
}


def fetch_workloads() -> dict:
    # Discover and evaluate every Deployment/StatefulSet/DaemonSet in the cluster.
    workloads = []
    errors = []
    for resource in WORKLOAD_KINDS:
        payload = _get_json(resource)
        if "error" in payload:
            errors.append({"resource": resource, "error": payload["error"]})
        for obj in payload.get("items", []):
            kind = obj.get("kind") or _kind_from_resource(resource)
            evaluator = _EVALUATORS.get(kind)
            if evaluator is None:
                continue
            metrics = evaluator(obj)
            workloads.append({
                "kind": kind,
                "namespace": obj.get("metadata", {}).get("namespace", ""),
                "name": obj.get("metadata", {}).get("name", ""),
                **metrics,
            })
    return {"workloads": workloads, "errors": errors}


def _kind_from_resource(resource: str) -> str:
    # `kubectl get <resource> -o json` items don't always carry a "kind" field,
    # so map the plural resource name back to its singular Kind.
    return {
        "deployments": "Deployment",
        "statefulsets": "StatefulSet",
        "daemonsets": "DaemonSet",
    }.get(resource, resource)


def fetch_unhealthy_pods() -> dict:
    # Surface pods that are crashing or otherwise misbehaving. A workload can
    # report the right replica count while a pod is stuck in CrashLoopBackOff,
    # so we inspect pods directly for "not crashing / no strange behavior".
    payload = _get_json("pods")
    errors = []
    if "error" in payload:
        errors.append({"resource": "pods", "error": payload["error"]})

    unhealthy = []
    for pod in payload.get("items", []):
        status = pod.get("status", {})
        phase = status.get("phase", "")

        # Succeeded pods (e.g. completed helm-install Jobs) are not failures.
        if phase == "Succeeded":
            continue

        reasons = []
        total_restarts = 0
        for cstatus in status.get("containerStatuses", []):
            total_restarts += cstatus.get("restartCount", 0)
            waiting = cstatus.get("state", {}).get("waiting")
            if waiting:
                reason = waiting.get("reason", "")
                if reason and reason not in TRANSIENT_WAITING_REASONS:
                    reasons.append(reason)

        is_unhealthy = phase == "Failed" or bool(reasons)
        if is_unhealthy:
            unhealthy.append({
                "namespace": pod.get("metadata", {}).get("namespace", ""),
                "name": pod.get("metadata", {}).get("name", ""),
                "phase": phase,
                "reasons": sorted(set(reasons)),
                "restarts": total_restarts,
            })

    return {"unhealthy_pods": unhealthy, "errors": errors}


def fetch_cronjobs() -> dict:
    # CronJobs (e.g. descheduler) don't have replica-readiness — they fire on a
    # schedule and sit idle in between. So "ready" here means: not suspended and
    # no recent owned Job has failed. A CronJob that has never run yet is still
    # ready; it simply hasn't reached its schedule.
    cj_payload = _get_json("cronjobs")
    job_payload = _get_json("jobs")
    errors = []
    if "error" in cj_payload:
        errors.append({"resource": "cronjobs", "error": cj_payload["error"]})
    if "error" in job_payload:
        errors.append({"resource": "jobs", "error": job_payload["error"]})

    # Count failed Jobs grouped by the CronJob that owns them, so we can attribute
    # a failing run back to its parent. A Job is failed when it carries a
    # condition of type "Failed" with status "True".
    failed_by_owner = {}
    for job in job_payload.get("items", []):
        owner = next(
            (o for o in job.get("metadata", {}).get("ownerReferences", [])
             if o.get("kind") == "CronJob"),
            None,
        )
        if owner is None:
            continue
        conditions = job.get("status", {}).get("conditions", [])
        failed = any(
            c.get("type") == "Failed" and c.get("status") == "True"
            for c in conditions
        )
        if failed:
            key = (job.get("metadata", {}).get("namespace", ""), owner.get("name", ""))
            failed_by_owner[key] = failed_by_owner.get(key, 0) + 1

    cronjobs = []
    for obj in cj_payload.get("items", []):
        meta = obj.get("metadata", {})
        namespace = meta.get("namespace", "")
        name = meta.get("name", "")
        status = obj.get("status", {})
        suspended = bool(obj.get("spec", {}).get("suspend", False))
        failed_jobs = failed_by_owner.get((namespace, name), 0)
        ready = (not suspended) and failed_jobs == 0
        cronjobs.append({
            "kind": "CronJob",
            "namespace": namespace,
            "name": name,
            "suspended": suspended,
            "failed_jobs": failed_jobs,
            "last_schedule_time": status.get("lastScheduleTime"),
            "last_successful_time": status.get("lastSuccessfulTime"),
            "ready": ready,
        })

    return {"cronjobs": cronjobs, "errors": errors}


def fetch_snapshot() -> dict:
    # A single point-in-time evaluation of all apps in the cluster.
    workload_data = fetch_workloads()
    cronjob_data = fetch_cronjobs()
    pod_data = fetch_unhealthy_pods()

    workloads = workload_data["workloads"]
    not_ready = [w for w in workloads if not w["ready"]]
    cronjobs = cronjob_data["cronjobs"]
    cronjobs_not_ready = [c for c in cronjobs if not c["ready"]]
    unhealthy_pods = pod_data["unhealthy_pods"]
    errors = workload_data["errors"] + cronjob_data["errors"] + pod_data["errors"]

    ready = (
        not errors
        and len(not_ready) == 0
        and len(cronjobs_not_ready) == 0
        and len(unhealthy_pods) == 0
    )

    return {
        "ready": ready,
        "summary": {
            "workloads_total": len(workloads),
            "workloads_ready": len(workloads) - len(not_ready),
            "workloads_not_ready": len(not_ready),
            "cronjobs_total": len(cronjobs),
            "cronjobs_ready": len(cronjobs) - len(cronjobs_not_ready),
            "cronjobs_not_ready": len(cronjobs_not_ready),
            "unhealthy_pods": len(unhealthy_pods),
        },
        "workloads": workloads,
        "cronjobs": cronjobs,
        "unhealthy_pods": unhealthy_pods,
        "errors": errors,
    }


def fetch_k8s_apps(wait_time: int = 0, poll_interval: int = 5) -> dict:
    # Evaluate app readiness. When wait_time > 0, keep polling until everything
    # is ready or the budget is exhausted — this absorbs apps that are still
    # rolling out (e.g. Traefik mid-startup). wait_time <= 0 returns a snapshot.
    start = time.monotonic()
    deadline = start + max(wait_time, 0)

    while True:
        snapshot = fetch_snapshot()
        if snapshot["ready"] or wait_time <= 0:
            break
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(poll_interval, remaining))

    snapshot["waited_seconds"] = round(time.monotonic() - start, 2)
    return snapshot


def _parse_args(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Check whether the apps deployed on the cluster are ready."
    )
    parser.add_argument(
        "--wait-time",
        type=int,
        default=0,
        metavar="SECONDS",
        help=(
            "Max seconds to wait for apps to transition from not-ready to ready. "
            "0 (default) returns an immediate snapshot of current state."
        ),
    )
    args = parser.parse_args(argv)
    if args.wait_time < 0:
        parser.error("--wait-time must be a non-negative integer")
    return args


if __name__ == "__main__":
    args = _parse_args()
    output = fetch_k8s_apps(wait_time=args.wait_time)
    print(json.dumps(output, indent=4))
    # Non-zero exit when not ready so E2E callers can branch on the result
    # without re-parsing the JSON.
    sys.exit(0 if output["ready"] else 1)
