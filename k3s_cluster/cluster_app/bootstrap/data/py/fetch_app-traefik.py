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


def _collect_inventory(resource: str, kind: str) -> tuple:
    # Traefik CRDs (IngressRoute/Middleware/...) do not write back a status or
    # Ready condition, so existence + parse-ability is the only signal the API
    # exposes. We report the inventory; cross-checking it against an expected set
    # of route/middleware names is the deferred "expected vs. absent" check.
    payload = get_resources(resource)
    entries = []
    errors = []
    if "error" in payload:
        errors.append({"resource": resource, "error": payload["error"]})
    for obj in payload.get("items", []):
        meta = obj.get("metadata", {})
        entries.append(
            {
                "kind": kind,
                "namespace": meta.get("namespace", ""),
                "name": meta.get("name", ""),
            }
        )
    return entries, errors


def fetch_traefik() -> dict:
    ingressroutes, ir_err = _collect_inventory("ingressroutes", "IngressRoute")
    middlewares, mw_err = _collect_inventory("middlewares", "Middleware")

    errors = ir_err + mw_err
    # "ready" here means the Traefik CRDs are installed and their objects are
    # queryable. Traefik's running health (the Deployment) is covered by
    # fetch_k3s-apps.py; route correctness needs the external expected-set check.
    ready = not errors

    return {
        "ready": ready,
        "summary": {
            "ingressroutes_total": len(ingressroutes),
            "middlewares_total": len(middlewares),
        },
        "ingressroutes": ingressroutes,
        "middlewares": middlewares,
        "errors": errors,
        "note": (
            "Traefik CRDs expose no readiness status; presence is the only "
            "in-cluster signal. Validate the inventory against an expected set "
            "from outside the cluster."
        ),
    }


if __name__ == "__main__":
    output = fetch_traefik()
    emit(output)
    sys.exit(0 if output["ready"] else 1)
