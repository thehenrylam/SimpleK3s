#!/usr/bin/env python3

# Builtin Modules
import importlib.util
import os
import sys

_dir = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "fetch_UTILITIES", os.path.join(_dir, "fetch_UTILITIES.py")
)
_utils = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_utils)
emit = _utils.emit
get_resources = _utils.get_resources

# Descheduler ships as a CronJob (no Deployment/Service), so there's no pod to
# poll and no HTTP endpoint — health is "the CronJob is active and its most
# recent Job succeeded". A failing schedule (bad RBAC, image pull, policy error)
# leaves the CronJob present but silently never evicting; the generic workload
# check can't see that.
CRONJOB_NAME = "descheduler"


def _job_state(job: dict) -> str:
    # Map a Job to one of: complete / failed / active. CronJob Jobs are one-shot,
    # so a finished Job carries a Complete or Failed condition.
    conds = {c.get("type"): c.get("status") for c in job.get("status", {}).get("conditions", [])}
    if conds.get("Complete") == "True":
        return "complete"
    if conds.get("Failed") == "True":
        return "failed"
    return "active"


def _find_cronjob(errors: list):
    payload = get_resources("cronjobs")
    if "error" in payload:
        errors.append({"resource": "cronjobs", "error": payload["error"]})
        return None
    for obj in payload.get("items", []):
        if obj.get("metadata", {}).get("name") == CRONJOB_NAME:
            return obj
    return None


def _owned_jobs(namespace: str, errors: list) -> list:
    # Only Jobs owned by the descheduler CronJob — the namespace (kube-system)
    # also holds unrelated helm-install-* Jobs we must not grade.
    payload = get_resources("jobs")
    if "error" in payload:
        errors.append({"resource": "jobs", "error": payload["error"]})
        return []
    jobs = []
    for obj in payload.get("items", []):
        meta = obj.get("metadata", {})
        if meta.get("namespace") != namespace:
            continue
        owners = meta.get("ownerReferences", [])
        if not any(o.get("kind") == "CronJob" and o.get("name") == CRONJOB_NAME for o in owners):
            continue
        jobs.append(
            {
                "name": meta.get("name", ""),
                "created": meta.get("creationTimestamp", ""),
                "state": _job_state(obj),
            }
        )
    return jobs


def fetch_descheduler() -> dict:
    errors: list = []
    cronjob = _find_cronjob(errors)

    if cronjob is None:
        return {
            "ready": True,
            "status": "not_deployed",
            "summary": {
                "suspended": False,
                "jobs_total": 0,
                "jobs_failed": 0,
                "latest_job_ok": True,
            },
            "details": {},
            "errors": errors,
            "note": f"CronJob {CRONJOB_NAME} not present; descheduler is not deployed here.",
        }

    meta = cronjob.get("metadata", {})
    spec = cronjob.get("spec", {})
    cj_status = cronjob.get("status", {})
    namespace = meta.get("namespace", "")
    suspended = bool(spec.get("suspend"))

    jobs = _owned_jobs(namespace, errors)
    finished = sorted((j for j in jobs if j["state"] != "active"), key=lambda j: j["created"])
    failed_count = sum(1 for j in jobs if j["state"] == "failed")
    latest = finished[-1] if finished else None
    # No finished Jobs yet (cluster younger than the schedule) is not a failure —
    # the schedule simply hasn't fired. Only a failed *latest* run is degraded.
    latest_job_ok = latest is None or latest["state"] == "complete"
    ready = (not suspended) and latest_job_ok

    return {
        "ready": ready,
        "status": "ok" if ready else "degraded",
        "summary": {
            "suspended": suspended,
            "jobs_total": len(jobs),
            "jobs_failed": failed_count,
            "latest_job_ok": latest_job_ok,
        },
        "details": {
            "namespace": namespace,
            "schedule": spec.get("schedule"),
            "last_schedule_time": cj_status.get("lastScheduleTime"),
            "last_successful_time": cj_status.get("lastSuccessfulTime"),
            "latest_job": latest,
            "jobs": jobs,
        },
        "errors": errors,
        "note": (
            "Asserts the descheduler CronJob is active (not suspended) and its most "
            "recent finished Job completed (no run yet is treated as pending, not failed)."
        ),
    }


if __name__ == "__main__":
    output = fetch_descheduler()
    emit(output)
    sys.exit(0 if output["ready"] else 1)
