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
get_failing_conditions = _utils.get_failing_conditions


def _collect(resource: str, kind: str, extra=None) -> tuple:
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
        # Pinpoint which sub-condition failed (SubnetsReady, AMIsReady, ...).
        entry["failing_conditions"] = get_failing_conditions(obj)
        if extra:
            entry.update(extra(obj))
        entries.append(entry)
    return entries, errors


def fetch_karpenter() -> dict:
    # EC2NodeClass + NodePool readiness == "is autoscaling correctly configured".
    # A misconfigured nodeclass (bad AMI/subnet/securitygroup selector) reports
    # Ready=False here while the Karpenter Deployment looks perfectly healthy —
    # i.e. autoscaling is silently broken.
    nodeclasses, nc_err = _collect("ec2nodeclasses", "EC2NodeClass")
    nodepools, np_err = _collect("nodepools", "NodePool")

    # NodeClaims represent live, in-flight node provisioning. They are ephemeral
    # (a node mid-launch is briefly not-Ready by design), so they are reported
    # for visibility but do NOT factor into deployment validity.
    nodeclaims, ncl_err = _collect(
        "nodeclaims",
        "NodeClaim",
        lambda o: {
            "node_name": o.get("status", {}).get("nodeName", ""),
            "provider_id": o.get("status", {}).get("providerID", ""),
        },
    )

    errors = nc_err + np_err + ncl_err
    config = nodeclasses + nodepools
    config_not_ready = [e for e in config if not e["ready"]]
    ready = not errors and len(config_not_ready) == 0

    return {
        "ready": ready,
        "summary": {
            "ec2nodeclasses_total": len(nodeclasses),
            "ec2nodeclasses_ready": len([e for e in nodeclasses if e["ready"]]),
            "nodepools_total": len(nodepools),
            "nodepools_ready": len([e for e in nodepools if e["ready"]]),
            "nodeclaims_total": len(nodeclaims),
            "nodeclaims_ready": len([e for e in nodeclaims if e["ready"]]),
            "config_not_ready": len(config_not_ready),
        },
        "ec2nodeclasses": nodeclasses,
        "nodepools": nodepools,
        # Informational: live scaling activity, not part of the readiness verdict.
        "nodeclaims": nodeclaims,
        "errors": errors,
    }


if __name__ == "__main__":
    output = fetch_karpenter()
    print(json.dumps(output, indent=4))
    sys.exit(0 if output["ready"] else 1)
