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
get_pvcs = _utils.get_pvcs

NS = "monitoring"
# Grafana's PVC is the plain "<release>-grafana" claim (the Deployment mounts it
# at /var/lib/grafana). Match by the "grafana" substring so a changed release
# prefix doesn't hide it.
COMPONENT = "grafana"


def fetch_grafana_pvc() -> dict:
    errors: list = []
    all_pvcs, err = get_pvcs(NS)
    if err:
        errors.append({"resource": "pvc", "error": err})

    pvcs = [p for p in all_pvcs if COMPONENT in p["name"]]
    for p in pvcs:
        p["component"] = COMPONENT

    if not pvcs:
        # No Grafana PVC: either Grafana isn't deployed here or it runs without
        # persistence (ephemeral). Neither is a failure on its own — the answer
        # sheet decides whether storage is expected for this cluster.
        return {
            "ready": True,
            "status": "no_pvcs",
            "summary": {"pvcs_total": 0, "pvcs_bound": 0, "pvcs_unbound": 0},
            "details": {"pvcs": []},
            "errors": errors,
            "note": (
                "No Grafana PersistentVolumeClaim found in the monitoring namespace; "
                "Grafana is either not deployed here or running without persistence."
            ),
        }

    bound = sum(1 for p in pvcs if p["bound"])
    unbound = len(pvcs) - bound
    ready = unbound == 0

    return {
        "ready": ready,
        "status": "ok" if ready else "degraded",
        "summary": {
            "pvcs_total": len(pvcs),
            "pvcs_bound": bound,
            "pvcs_unbound": unbound,
        },
        "details": {"pvcs": pvcs},
        "errors": errors,
        "note": (
            "Lists Grafana's monitoring-namespace PersistentVolumeClaim(s), their "
            "StorageClass and capacity, and asserts every claim is Bound."
        ),
    }


if __name__ == "__main__":
    output = fetch_grafana_pvc()
    emit(output)
    sys.exit(0 if output["ready"] else 1)
