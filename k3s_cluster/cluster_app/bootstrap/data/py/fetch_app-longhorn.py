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

NS = "longhorn-system"
MANAGER_DS = "longhorn-manager"
CSI_PLUGIN_DS = "longhorn-csi-plugin"
# The CSI sidecar Deployments the longhorn-driver-deployer creates. Each must have
# all replicas Ready for provisioning/attach/resize/snapshot to work end to end.
CSI_DEPLOYMENTS = ("csi-attacher", "csi-provisioner", "csi-resizer", "csi-snapshotter")
# The CSI driver name the node-driver-registrar registers with the kubelet. A node
# missing this from its CSINode object cannot MOUNT Longhorn volumes — the exact
# failure the csi.kubeletRootDir path mismatch produced ("driver name
# driver.longhorn.io not found in the list of registered CSI drivers").
DRIVER_NAME = "driver.longhorn.io"


def _find_daemonset(name: str, errors: list):
    payload = get_resources("daemonsets")
    if "error" in payload:
        errors.append({"resource": "daemonsets", "error": payload["error"]})
        return None
    for obj in payload.get("items", []):
        meta = obj.get("metadata", {})
        if meta.get("namespace") == NS and meta.get("name") == name:
            return obj
    return None


def _ds_health(ds: dict) -> dict:
    # A DaemonSet is healthy when every scheduled pod is Ready.
    status = (ds or {}).get("status", {})
    desired = status.get("desiredNumberScheduled", 0)
    ready = status.get("numberReady", 0)
    return {"desired": desired, "ready": ready, "ok": desired > 0 and ready == desired}


def _csi_deployments(errors: list) -> tuple:
    # Grade each CSI sidecar Deployment by readyReplicas == spec.replicas.
    payload = get_resources("deployments")
    if "error" in payload:
        errors.append({"resource": "deployments", "error": payload["error"]})
        return [], 0
    deployments = []
    ready_count = 0
    by_name = {
        obj.get("metadata", {}).get("name", ""): obj
        for obj in payload.get("items", [])
        if obj.get("metadata", {}).get("namespace") == NS
    }
    for name in CSI_DEPLOYMENTS:
        obj = by_name.get(name)
        if obj is None:
            deployments.append({"name": name, "desired": 0, "ready": 0, "ok": False})
            continue
        desired = obj.get("spec", {}).get("replicas", 0)
        ready = obj.get("status", {}).get("readyReplicas", 0)
        ok = desired > 0 and ready == desired
        ready_count += 1 if ok else 0
        deployments.append({"name": name, "desired": desired, "ready": ready, "ok": ok})
    return deployments, ready_count


def _csi_registration(errors: list) -> tuple:
    # For each CSINode object, record whether driver.longhorn.io is registered.
    # This is the kubelet's in-memory view; without it the node cannot mount.
    payload = get_resources("csinode")
    if "error" in payload:
        errors.append({"resource": "csinode", "error": payload["error"]})
        return [], 0
    nodes = []
    registered = 0
    for obj in payload.get("items", []):
        name = obj.get("metadata", {}).get("name", "")
        drivers = [d.get("name") for d in obj.get("spec", {}).get("drivers") or []]
        has_driver = DRIVER_NAME in drivers
        registered += 1 if has_driver else 0
        nodes.append({"node": name, "registered": has_driver})
    return nodes, registered


def _storage_classes(errors: list) -> list:
    payload = get_resources("storageclass")
    if "error" in payload:
        errors.append({"resource": "storageclass", "error": payload["error"]})
        return []
    classes = []
    for obj in payload.get("items", []):
        if obj.get("provisioner") != DRIVER_NAME:
            continue
        meta = obj.get("metadata", {})
        annotations = meta.get("annotations", {}) or {}
        classes.append(
            {
                "name": meta.get("name", ""),
                "default": annotations.get("storageclass.kubernetes.io/is-default-class") == "true",
            }
        )
    return classes


def _longhorn_nodes(errors: list) -> tuple:
    # Longhorn's own nodes.longhorn.io CRs report disk scheduling health. A node
    # that is Ready but not Schedulable has no usable disk (e.g. the pool EBS
    # volume never mounted), so replicas can't be placed there.
    payload = get_resources("nodes.longhorn.io")
    if "error" in payload:
        errors.append({"resource": "nodes.longhorn.io", "error": payload["error"]})
        return [], 0
    nodes = []
    schedulable = 0
    for obj in payload.get("items", []):
        conds = {
            c.get("type"): c.get("status") for c in obj.get("status", {}).get("conditions", [])
        }
        is_ready = conds.get("Ready") == "True"
        is_schedulable = conds.get("Schedulable") == "True"
        schedulable += 1 if is_schedulable else 0
        nodes.append(
            {
                "node": obj.get("metadata", {}).get("name", ""),
                "ready": is_ready,
                "schedulable": is_schedulable,
            }
        )
    return nodes, schedulable


def fetch_longhorn() -> dict:
    errors: list = []
    manager = _find_daemonset(MANAGER_DS, errors)

    if manager is None:
        # No longhorn-manager DaemonSet => the Longhorn subsystem is not deployed.
        return {
            "ready": True,
            "status": "not_deployed",
            "summary": {
                "manager_ok": False,
                "csi_plugin_ok": False,
                "csi_deployments_ready": 0,
                "csi_deployments_total": len(CSI_DEPLOYMENTS),
                "csinodes_registered": 0,
                "csinodes_expected": 0,
                "all_csi_registered": False,
                "storage_classes": 0,
                "longhorn_nodes_schedulable": 0,
                "longhorn_nodes_total": 0,
            },
            "details": {},
            "errors": errors,
            "note": f"DaemonSet {MANAGER_DS} not present; Longhorn is not deployed here.",
        }

    manager_health = _ds_health(manager)
    plugin = _find_daemonset(CSI_PLUGIN_DS, errors)
    plugin_health = _ds_health(plugin) if plugin else {"desired": 0, "ready": 0, "ok": False}

    deployments, csi_ready = _csi_deployments(errors)
    csinodes, registered = _csi_registration(errors)
    storage_classes = _storage_classes(errors)
    lh_nodes, schedulable = _longhorn_nodes(errors)

    # Nodes that should carry the CSI driver = where the csi-plugin DaemonSet runs.
    csinodes_expected = plugin_health["desired"]
    all_csi_registered = csinodes_expected > 0 and registered >= csinodes_expected

    ready = (
        manager_health["ok"]
        and plugin_health["ok"]
        and csi_ready == len(CSI_DEPLOYMENTS)
        and all_csi_registered
        and len(storage_classes) > 0
        and len(lh_nodes) > 0
        and schedulable == len(lh_nodes)
    )

    return {
        "ready": ready,
        "status": "ok" if ready else "degraded",
        "summary": {
            "manager_ok": manager_health["ok"],
            "csi_plugin_ok": plugin_health["ok"],
            "csi_deployments_ready": csi_ready,
            "csi_deployments_total": len(CSI_DEPLOYMENTS),
            "csinodes_registered": registered,
            "csinodes_expected": csinodes_expected,
            "all_csi_registered": all_csi_registered,
            "storage_classes": len(storage_classes),
            "longhorn_nodes_schedulable": schedulable,
            "longhorn_nodes_total": len(lh_nodes),
        },
        "details": {
            "manager": manager_health,
            "csi_plugin": plugin_health,
            "csi_deployments": deployments,
            "csinodes": csinodes,
            "storage_classes": storage_classes,
            "longhorn_nodes": lh_nodes,
        },
        "errors": errors,
        "note": (
            "Asserts the longhorn-manager and longhorn-csi-plugin DaemonSets are fully "
            "rolled out, all CSI sidecar Deployments are Ready, driver.longhorn.io is "
            "registered on every node running the CSI plugin (the mount path that the "
            "csi.kubeletRootDir mismatch broke), at least one Longhorn StorageClass "
            "exists, and every Longhorn node is Schedulable."
        ),
    }


if __name__ == "__main__":
    output = fetch_longhorn()
    emit(output)
    sys.exit(0 if output["ready"] else 1)
