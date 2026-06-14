#!/usr/bin/env python3

# Builtin Modules
import importlib.util
import json
import os
import sys

_dir = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "fetch_UTILITIES", os.path.join(_dir, "fetch_UTILITIES.py")
)
_utils = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_utils)
get_resources = _utils.get_resources
get_ready_condition = _utils.get_ready_condition


def _policy_extra(obj: dict) -> dict:
    spec = obj.get("spec", {})
    # validationFailureAction (Audit vs Enforce) is essential context: an
    # Enforce policy that mis-fires actively blocks workloads from scheduling,
    # so the external validator should treat Enforce + not-ready as high risk.
    return {
        "validation_failure_action": spec.get("validationFailureAction", ""),
        "background": spec.get("background"),
    }


def _collect(resource: str, kind: str) -> tuple:
    payload = get_resources(resource)
    entries = []
    errors = []
    if "error" in payload:
        errors.append({"resource": resource, "error": payload["error"]})
    for obj in payload.get("items", []):
        meta = obj.get("metadata", {})
        entry = {
            "kind": kind,
            "namespace": meta.get("namespace", ""),
            "name": meta.get("name", ""),
        }
        entry.update(get_ready_condition(obj))
        entry.update(_policy_extra(obj))
        entries.append(entry)
    return entries, errors


def fetch_kyverno() -> dict:
    # ClusterPolicy Ready=True means the policy was admitted and its webhooks are
    # wired up. A policy stuck not-ready means the guardrail isn't enforcing (or,
    # worse, is half-applied and rejecting pods).
    cluster_policies, cp_err = _collect("clusterpolicies", "ClusterPolicy")
    # Namespaced Policies aren't deployed today, but scanning keeps us covered if
    # they're added later.
    policies, p_err = _collect("policies", "Policy")

    errors = cp_err + p_err
    not_ready = [e for e in cluster_policies + policies if not e["ready"]]
    ready = not errors and len(not_ready) == 0

    return {
        "ready": ready,
        "summary": {
            "cluster_policies_total": len(cluster_policies),
            "cluster_policies_ready": len([e for e in cluster_policies if e["ready"]]),
            "policies_total": len(policies),
            "policies_ready": len([e for e in policies if e["ready"]]),
            "not_ready": len(not_ready),
        },
        "cluster_policies": cluster_policies,
        "policies": policies,
        "errors": errors,
    }


if __name__ == "__main__":
    output = fetch_kyverno()
    print(json.dumps(output, indent=4))
    sys.exit(0 if output["ready"] else 1)
