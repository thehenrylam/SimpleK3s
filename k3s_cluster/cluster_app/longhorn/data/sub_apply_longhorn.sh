#!/bin/bash

# Set bash flags
set -euo pipefail
# -u            : Error if an unset variable is referenced
# -e            : Exits on ANY command failure
# -o pipefail   : Make pipeline fail if any command in them fails

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

function wait_longhorn() {
    local NS="longhorn-system"

    log_info "Waiting for Longhorn HelmChart job to complete..."
    wait_for_cmd_3min sudo kubectl -n kube-system get job helm-install-longhorn || {
        log_fail "Longhorn HelmChart install job never appeared"
        sudo kubectl -n kube-system get helmcharts || true
        return 1
    }

    wait_for_cmd_3min sudo kubectl -n kube-system wait \
        --for=condition=complete \
        job/helm-install-longhorn \
        --timeout=10s || {
        log_fail "Longhorn HelmChart install job did not complete"
        sudo kubectl -n kube-system describe job helm-install-longhorn || true
        return 1
    }

    log_info "Waiting for longhorn-manager DaemonSet to be ready..."
    wait_for_cmd_3min sudo kubectl -n "$NS" get daemonset longhorn-manager || {
        log_fail "longhorn-manager DaemonSet never appeared in namespace '$NS'"
        sudo kubectl -n "$NS" get all || true
        return 1
    }

    wait_for_cmd_3min sudo kubectl -n "$NS" rollout status daemonset/longhorn-manager --timeout=10s || {
        log_fail "longhorn-manager DaemonSet did not become ready"
        sudo kubectl -n "$NS" get pods -l app=longhorn-manager -o wide || true
        return 1
    }

    log_info "Waiting for Longhorn CSI driver pods to be ready..."
    # longhorn-csi-plugin is created by longhorn-manager after it starts, not directly by Helm.
    # Give it 5 minutes to appear and become ready; rollout status handles both "not yet created"
    # (exits non-zero immediately, retried by wait_for_cmd_5min) and "not yet rolled out".
    wait_for_cmd_5min sudo kubectl -n "$NS" rollout status daemonset/longhorn-csi-plugin --timeout=10s || {
        log_fail "longhorn-csi-plugin DaemonSet never appeared or did not become ready — diagnostic dump:"

        log_info "--- Pod list ---"
        sudo kubectl -n "$NS" get pods -l app=longhorn-csi-plugin -o wide || true

        log_info "--- Pod describe (first non-Running pod) ---"
        local FAILED_POD
        FAILED_POD="$(sudo kubectl -n "$NS" get pods -l app=longhorn-csi-plugin \
            --field-selector='status.phase!=Running' \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
        if [[ -n "$FAILED_POD" ]]; then
            sudo kubectl -n "$NS" describe pod "$FAILED_POD" || true

            log_info "--- Container logs: longhorn-csi-plugin ---"
            sudo kubectl -n "$NS" logs "$FAILED_POD" -c longhorn-csi-plugin --tail=50 2>/dev/null || true

            log_info "--- Container logs: node-driver-registrar ---"
            sudo kubectl -n "$NS" logs "$FAILED_POD" -c node-driver-registrar --tail=30 2>/dev/null || true

            log_info "--- Container logs: liveness-probe ---"
            sudo kubectl -n "$NS" logs "$FAILED_POD" -c liveness-probe --tail=20 2>/dev/null || true
        fi

        log_info "--- longhorn-manager logs (last 30 lines) ---"
        sudo kubectl -n "$NS" logs -l app=longhorn-manager --tail=30 2>/dev/null || true

        return 1
    }

    log_okay "Longhorn is ready (manager and CSI driver DaemonSets are running)."
}

function wait_csi_registered() {
    # The CSI plugin pod being Ready (3/3) does not mean the driver has registered with
    # the kubelet. node-driver-registrar creates a Unix socket under the kubelet's
    # plugins_registry/ directory; the kubelet watches that directory, calls GetInfo on the
    # socket, registers the driver internally, and populates the node's CSINode object.
    #
    # For this to work, csi.kubeletRootDir in longhorn.yaml.tmpl MUST point at the kubelet's
    # real root dir (this K3s install uses the standard /var/lib/kubelet). If it points
    # elsewhere, the socket lands in a directory the kubelet never watches: attach can still
    # be forced (the attach/detach controller only reads CSINode), but mounts fail with
    # "driver name driver.longhorn.io not found in the list of registered CSI drivers".
    # We therefore only wait for *natural* registration here and fail loudly if it does not
    # happen — a populated CSINode is the signal the kubelet has truly registered the driver.
    log_info "Waiting for Longhorn CSI driver to register on all nodes..."

    local NODES
    NODES="$(sudo kubectl get nodes -o jsonpath='{.items[*].metadata.name}')"

    local NODE
    for NODE in $NODES; do
        if ! wait_for_cmd_3min bash -c \
            "sudo kubectl get csinode '$NODE' \
                -o jsonpath='{.spec.drivers[*].name}' 2>/dev/null \
             | grep -q 'driver.longhorn.io'"; then
            log_fail "Node '$NODE': driver.longhorn.io did not register with the kubelet."
            log_info "Check that csi.kubeletRootDir in longhorn.yaml matches the kubelet root"
            log_info "(the directory containing pods/ and plugins_registry/)."
            sudo kubectl get csinode "$NODE" -o yaml || true
            return 1
        fi
        log_okay "Node '$NODE': driver.longhorn.io registered."
    done

    log_okay "Longhorn CSI driver registered on all nodes."
}

function register_longhorn_disks() {
    # Longhorn reads longhorn.io/default-disks-annotation only when it first discovers a node.
    # If a nodes.longhorn.io object already exists with disks:{} (e.g. after a reinstall),
    # Longhorn will not re-read the annotation. This function patches every node's
    # nodes.longhorn.io spec directly so disk registration is idempotent across reinstalls.
    log_info "Ensuring Longhorn disk entries match node annotations..."

    local NODES
    NODES="$(sudo kubectl get nodes -o jsonpath='{.items[*].metadata.name}')"

    local NODE
    for NODE in $NODES; do
        local ANNOTATION
        ANNOTATION="$(sudo kubectl get node "$NODE" \
            -o jsonpath='{.metadata.annotations.longhorn\.io/default-disks-annotation}' \
            2>/dev/null || true)"

        if [[ -z "$ANNOTATION" ]]; then
            log_info "Node '$NODE': no longhorn.io/default-disks-annotation; skipping."
            continue
        fi

        local CURRENT_DISKS
        CURRENT_DISKS="$(sudo kubectl -n longhorn-system get nodes.longhorn.io "$NODE" \
            -o jsonpath='{.spec.disks}' 2>/dev/null || true)"

        if [[ -n "$CURRENT_DISKS" && "$CURRENT_DISKS" != "{}" ]]; then
            log_info "Node '$NODE': disks already registered; skipping."
            continue
        fi

        log_info "Node '$NODE': patching nodes.longhorn.io from annotation..."
        local PATCH
        PATCH="$(echo "$ANNOTATION" | python3 -c "
import json, sys
annotation = json.load(sys.stdin)
disks = {}
for path, cfg in annotation.items():
    key = path.strip('/').replace('/', '-')
    disks[key] = {
        'allowScheduling': cfg.get('allowScheduling', True),
        'diskType': 'filesystem',
        'evictionRequested': False,
        'path': path,
        'storageReserved': cfg.get('storageReserved', 0),
        'tags': cfg.get('tags', [])
    }
print(json.dumps({'spec': {'disks': disks}}))
")"
        sudo kubectl -n longhorn-system patch nodes.longhorn.io "$NODE" \
            --type=merge -p "$PATCH" || {
            log_fail "Node '$NODE': failed to patch nodes.longhorn.io disk spec."
            return 1
        }
        log_okay "Node '$NODE': disk spec patched."
    done

    log_okay "Longhorn disk registration complete."
}

function apply_longhorn() {
    log_info "Writing Longhorn manifest"

    log_info "Make sure that '$K3S_MANIFEST_DIR/' is initialized"
    sudo mkdir -p "$K3S_MANIFEST_DIR/" || return 1
    log_okay "Confirmed that '$K3S_MANIFEST_DIR/' has been initialized"

    local PENDING_FILEPATH="$SCRIPT_DIR/manifests/longhorn.yaml"
    local MANIFEST_FILEPATH="$K3S_MANIFEST_DIR/longhorn.yaml"
    log_info "Apply Longhorn to $MANIFEST_FILEPATH"
    sudo cp "$PENDING_FILEPATH" "$MANIFEST_FILEPATH" || return 1
    log_okay "Longhorn written to $MANIFEST_FILEPATH"

    log_okay "Wrote Longhorn manifest"
}

log_info "$0: LAUNCHED"

wait_for_k3s_api || {
    log_fail "Unable to confirm that K3s API is ready"
    exit 1
}

wait_for_kubesystem || {
    log_fail "Unable to confirm that Kubesystem is ready"
    exit 1
}

apply_longhorn || {
    log_fail "Failed to apply Longhorn"
    exit 1
}

wait_longhorn || {
    log_fail "Unable to confirm that Longhorn is ready"
    exit 1
}

wait_csi_registered || {
    log_fail "Longhorn CSI driver did not register with the kubelet"
    exit 1
}

register_longhorn_disks || {
    log_fail "Failed to register Longhorn disk entries"
    exit 1
}

log_okay "$0: COMPLETED"
