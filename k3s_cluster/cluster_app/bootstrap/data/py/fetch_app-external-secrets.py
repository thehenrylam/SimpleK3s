#!/usr/bin/env python3

# Builtin Modules
import importlib.util
import os
import json
import sys

_dir = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "fetch_UTILITIES",
    os.path.join(_dir, "fetch_UTILITIES.py")
)
_utils = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_utils)
get_resources = _utils.get_resources
get_ready_condition = _utils.get_ready_condition


def _collect(resource: str, kind: str, extra=None) -> tuple:
    # Evaluate every instance of a resource kind by its Ready condition.
    # `extra` is an optional callable returning additional fields per object.
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
        if extra:
            entry.update(extra(obj))
        entries.append(entry)
    return entries, errors


def fetch_external_secrets() -> dict:
    # ExternalSecret: Ready=True with reason "SecretSynced" means the secret was
    # pulled from AWS Parameter Store successfully. A failed sync (bad IAM,
    # missing parameter) leaves a workload running but non-functional — the gap
    # the generic workload check can't see.
    external_secrets, es_err = _collect(
        "externalsecrets", "ExternalSecret",
        lambda o: {"refresh_time": o.get("status", {}).get("refreshTime")},
    )
    # SecretStore / ClusterSecretStore: Ready=True (reason "Valid") means the
    # provider connection (AWS auth) is configured correctly.
    secret_stores, ss_err = _collect("secretstores", "SecretStore")
    cluster_stores, css_err = _collect("clustersecretstores", "ClusterSecretStore")

    stores = secret_stores + cluster_stores
    errors = es_err + ss_err + css_err
    not_ready = [e for e in external_secrets + stores if not e["ready"]]
    ready = not errors and len(not_ready) == 0

    return {
        "ready": ready,
        "summary": {
            "external_secrets_total": len(external_secrets),
            "external_secrets_ready": len([e for e in external_secrets if e["ready"]]),
            "secret_stores_total": len(stores),
            "secret_stores_ready": len([e for e in stores if e["ready"]]),
            "not_ready": len(not_ready),
        },
        "external_secrets": external_secrets,
        "secret_stores": stores,
        "errors": errors,
    }


if __name__ == "__main__":
    output = fetch_external_secrets()
    print(json.dumps(output, indent=4))
    sys.exit(0 if output["ready"] else 1)
