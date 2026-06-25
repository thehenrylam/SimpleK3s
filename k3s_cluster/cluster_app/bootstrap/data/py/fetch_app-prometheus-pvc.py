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
# The Prometheus operator's StatefulSet volumeClaimTemplates produce names like
# "prometheus-<release>-prometheus-db-..." and
# "alertmanager-<release>-alertmanager-db-...". Note an Alertmanager PVC name also
# contains "prometheus" (the release is "kube-prometheus"), so classify
# alertmanager FIRST — otherwise the substring match would mislabel it.
COMPONENTS = ("alertmanager", "prometheus")


def _classify(name: str) -> str:
    if "alertmanager" in name:
        return "alertmanager"
    if "prometheus" in name:
        return "prometheus"
    return "other"


def fetch_prometheus_pvc() -> dict:
    errors: list = []
    all_pvcs, err = get_pvcs(NS)
    if err:
        errors.append({"resource": "pvc", "error": err})

    pvcs = []
    for p in all_pvcs:
        component = _classify(p["name"])
        if component not in COMPONENTS:
            continue
        p["component"] = component
        pvcs.append(p)

    if not pvcs:
        # No Prometheus/Alertmanager PVCs: either the stack isn't deployed here or
        # it runs without persistence (ephemeral). Neither is a failure on its own
        # — the answer sheet decides whether storage is expected for this cluster.
        return {
            "ready": True,
            "status": "no_pvcs",
            "summary": {
                "pvcs_total": 0,
                "pvcs_bound": 0,
                "pvcs_unbound": 0,
                "components_with_pvc": [],
            },
            "details": {"pvcs": []},
            "errors": errors,
            "note": (
                "No Prometheus or Alertmanager PersistentVolumeClaim found in the "
                "monitoring namespace; the stack is either not deployed here or "
                "running without persistence."
            ),
        }

    bound = sum(1 for p in pvcs if p["bound"])
    unbound = len(pvcs) - bound
    components_with_pvc = sorted({p["component"] for p in pvcs})
    ready = unbound == 0

    return {
        "ready": ready,
        "status": "ok" if ready else "degraded",
        "summary": {
            "pvcs_total": len(pvcs),
            "pvcs_bound": bound,
            "pvcs_unbound": unbound,
            "components_with_pvc": components_with_pvc,
        },
        "details": {"pvcs": pvcs},
        "errors": errors,
        "note": (
            "Lists the Prometheus and Alertmanager monitoring-namespace "
            "PersistentVolumeClaims, their StorageClass and capacity, and asserts "
            "every claim is Bound."
        ),
    }


if __name__ == "__main__":
    output = fetch_prometheus_pvc()
    emit(output)
    sys.exit(0 if output["ready"] else 1)
