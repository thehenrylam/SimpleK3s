#!/bin/bash

# Set bash flags
set -euo pipefail
# -u            : Error if an unset variable is referenced
# -e            : Exits on ANY command failure
# -o pipefail   : Make pipeline fail if any command in them fails

# Stage ALL rendered manifests into the K3s manifest dir and let the cluster
# converge (level-triggered reconciliation), instead of applying components one
# at a time with per-component readiness waits. The K3s deploy controller
# retries failed applies, so manifests that depend on CRDs from other charts
# (e.g. karpenter-nodepool, traefik-middleware) converge on their own once their
# dependency is up.
#
# CAVEAT: that guarantee covers failed APPLIES only. A manifest that applies
# cleanly and is then abandoned by its own controller is invisible here, because
# the deploy controller has nothing left to retry. tailscale-ingress is exactly
# that case (#126); components like it are repaired in converge_actions.sh.
#
# The ordering exceptions are the "head" charts, staged and gated BEFORE the
# single-pass staging of everything else:
#   - Kyverno: its admission webhooks must be in place before any other
#     component is admitted, so baseline policies cover the whole platform.
#   - karpenter-crd: the main karpenter chart bundles the same CRDs in its
#     crds/ directory and Helm creates those WITHOUT release ownership
#     metadata. If the main chart wins the race, the karpenter-crd release can
#     never install ("exists and cannot be imported") — an ownership conflict
#     that retries cannot converge. Staging karpenter-crd first (gated on its
#     CRDs existing) makes the main chart skip its bundled copies.
#
# Besides staging, this script performs cluster-side PREP for built-in services
# whose declarative inputs must exist before the service converges (currently:
# the Longhorn disk annotations, which Longhorn reads when it first discovers a
# node). Genuinely imperative POST-convergence fix-ups live in
# converge_actions.sh instead.
#
# This script is idempotent and re-runnable: re-syncing the bootstrap dir from
# S3 and re-running it is the cluster's update mechanism (the deploy controller
# re-applies changed manifests; identical content is skipped).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Retrieve the common functions from common.sh (Calls upon simplek3s.env file)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

PENDING_MANIFEST_DIR="$SCRIPT_DIR/manifests"

# Kyverno files staged (in this order) ahead of everything else
KYVERNO_MANIFESTS=(
    "kyverno.yaml"
    "kyverno-baseline-policies.yaml"
)

# Karpenter CRD chart, staged ahead of the main karpenter chart (see header)
KARPENTER_CRD_MANIFEST="karpenter-crd-helmchart.yaml"

# Everything staged by the ordered head; skipped by stage_remaining_manifests
HEAD_MANIFESTS=(
    "${KYVERNO_MANIFESTS[@]}"
    "$KARPENTER_CRD_MANIFEST"
)

function stage_manifest() {
    local FILENAME="$1"
    local PENDING_FILEPATH="$PENDING_MANIFEST_DIR/$FILENAME"
    local MANIFEST_FILEPATH="$K3S_MANIFEST_DIR/$FILENAME"

    log_info "Staging manifest '$FILENAME' to $MANIFEST_FILEPATH"
    sudo cp "$PENDING_FILEPATH" "$MANIFEST_FILEPATH" || return 1
    log_okay "Staged manifest '$FILENAME'"
}

function wait_kyverno() {
    local NS="kyverno"

    log_info "Waiting for namespace '$NS' to be present..."
    wait_for_cmd_3min sudo kubectl get ns "$NS" || {
        log_fail "namespace '$NS' never appeared"
        return 1
    }

    # Wait for the key deployments (names match current Kyverno chart defaults)
    local deploys=(
        "kyverno-admission-controller"
        "kyverno-background-controller"
        "kyverno-cleanup-controller"
    )

    local d
    for d in "${deploys[@]}"; do
        log_info "Waiting for deployment '$d' to be present..."
        wait_for_cmd_3min sudo kubectl -n "$NS" get deploy "$d" || {
            log_fail "deployment '$d' never appeared in namespace '$NS'"
            sudo kubectl -n "$NS" get all || true
            return 1
        }

        log_info "Waiting for deployment '$d' to be ready..."
        wait_for_cmd_1min sudo kubectl -n "$NS" rollout status "deploy/$d" --timeout=10s || {
            log_fail "deployment '$d' not ready"
            sudo kubectl -n "$NS" describe deploy "$d" || true
            sudo kubectl -n "$NS" get pods -o wide || true
            return 1
        }
    done

    # Wait for Kyverno CRDs (so policies can be created)
    log_info "Waiting for Kyverno CRDs..."
    wait_for_cmd_3min bash -c \
      "sudo kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1 && sudo kubectl get crd policies.kyverno.io >/dev/null 2>&1" || {
        log_fail "Kyverno CRDs not ready"
        sudo kubectl get crd | grep kyverno || true
        return 1
    }

    log_okay "Kyverno is ready (controllers + CRDs present)."
}

function stage_kyverno_first() {
    # Kyverno may be absent (subsystem disabled); nothing to gate on then
    if [ ! -f "$PENDING_MANIFEST_DIR/kyverno.yaml" ]; then
        log_info "No Kyverno manifest present; skipping the Kyverno-first gate"
        return 0
    fi

    local FILENAME
    for FILENAME in "${KYVERNO_MANIFESTS[@]}"; do
        if [ -f "$PENDING_MANIFEST_DIR/$FILENAME" ]; then
            stage_manifest "$FILENAME" || return 1
        fi
    done

    wait_kyverno || return 1
}

function wait_karpenter_crds() {
    # Only the CRDs need to exist (registered by the karpenter-crd release)
    # before the main karpenter chart is staged; no controller readiness needed.
    log_info "Waiting for the Karpenter CRDs (owned by the karpenter-crd release)..."
    wait_for_cmd_3min bash -c \
      "sudo kubectl get crd ec2nodeclasses.karpenter.k8s.aws >/dev/null 2>&1 \
        && sudo kubectl get crd nodepools.karpenter.sh >/dev/null 2>&1 \
        && sudo kubectl get crd nodeclaims.karpenter.sh >/dev/null 2>&1" || {
        log_fail "Karpenter CRDs never appeared"
        sudo kubectl -n kube-system get job helm-install-karpenter-crd || true
        sudo kubectl -n kube-system logs -l helmcharts.helm.cattle.io/chart=karpenter-crd --tail=30 || true
        return 1
    }
    log_okay "Karpenter CRDs are registered."
}

function stage_karpenter_crd_first() {
    # Karpenter may be absent (subsystem disabled); nothing to gate on then
    if [ ! -f "$PENDING_MANIFEST_DIR/$KARPENTER_CRD_MANIFEST" ]; then
        log_info "No karpenter-crd manifest present; skipping the karpenter-crd gate"
        return 0
    fi

    stage_manifest "$KARPENTER_CRD_MANIFEST" || return 1

    wait_karpenter_crds || return 1
}

# Annotate every node with its Longhorn disks BEFORE longhorn.yaml is staged:
# Longhorn reads longhorn.io/default-disks-annotation only when it FIRST
# discovers a node, so the annotation must be in place before the manager
# daemonset starts. (converge_actions.sh patches nodes.longhorn.io afterwards
# as the safety net for any node Longhorn discovered before its annotation.)
#
# All pools that target a node are MERGED into one annotation — a per-pool
# --overwrite would keep only the last pool. Pool -> node matching mirrors
# bts_04: node_target is "controlplane", "agentplane", or "all", resolved via
# the node-role.kubernetes.io/control-plane label.
#
# Nodes that join after this step (e.g. a replaced node) are healed by
# re-running this script and converge_actions.sh.
function prep_longhorn_disk_annotations() {
    local POOLS_CONFIG_FILE="$SCRIPT_DIR/longhorn_pools_config.json"

    # Longhorn subsystem not enabled; nothing to annotate
    if [ ! -f "$POOLS_CONFIG_FILE" ]; then
        log_info "No Longhorn pools config present; skipping disk annotations"
        return 0
    fi

    log_info "Annotating nodes with their Longhorn disk configuration..."

    # The program is passed via -c (not stdin) so stdin stays free for the
    # node list piped in from kubectl. Emits "<node>\t<annotation-json>" lines.
    local PYPROG
    PYPROG="$(cat <<'PYEOF'
import json
import sys

with open(sys.argv[1]) as f:
    pools = json.load(f)

nodes = json.load(sys.stdin)["items"]

for node in nodes:
    name = node["metadata"]["name"]
    labels = node["metadata"].get("labels", {})
    is_controlplane = labels.get("node-role.kubernetes.io/control-plane") == "true"
    plane = "controlplane" if is_controlplane else "agentplane"

    disks = {}
    for pool in pools:
        if pool["node_target"] not in ("all", plane):
            continue
        disks[pool["disk_path"]] = {
            "allowScheduling": True,
            "storageReserved": 0,
            "tags": [pool["name"]],
        }

    if disks:
        print(f"{name}\t{json.dumps(disks, separators=(',', ':'))}")
PYEOF
)"

    local NODE_ANNOTATIONS
    NODE_ANNOTATIONS="$(sudo kubectl get nodes -o json | python3 -c "$PYPROG" "$POOLS_CONFIG_FILE")" || {
        log_fail "Failed to compute the Longhorn disk annotations"
        return 1
    }

    if [ -z "$NODE_ANNOTATIONS" ]; then
        log_info "No nodes match any pool's node_target; nothing to annotate"
        return 0
    fi

    local NODE ANNOTATION
    while IFS=$'\t' read -r NODE ANNOTATION; do
        [ -z "$NODE" ] && continue

        log_info "Node '$NODE': setting longhorn.io/default-disks-annotation"
        sudo kubectl annotate node "$NODE" \
            "longhorn.io/default-disks-annotation=$ANNOTATION" \
            --overwrite || {
            log_fail "Node '$NODE': failed to set longhorn.io/default-disks-annotation"
            return 1
        }
    done <<< "$NODE_ANNOTATIONS"

    log_okay "Longhorn disk annotations set."
}

function stage_remaining_manifests() {
    local PENDING_FILEPATH
    local FILENAME
    local IS_HEAD
    local HEAD_FILENAME

    for PENDING_FILEPATH in "$PENDING_MANIFEST_DIR"/*.yaml; do
        # No manifests at all (glob did not expand)
        [ -e "$PENDING_FILEPATH" ] || continue

        FILENAME="$(basename "$PENDING_FILEPATH")"

        # Skip the head manifests (already staged by the ordered head above)
        IS_HEAD="false"
        for HEAD_FILENAME in "${HEAD_MANIFESTS[@]}"; do
            if [ "$FILENAME" == "$HEAD_FILENAME" ]; then
                IS_HEAD="true"
                break
            fi
        done
        if [ "$IS_HEAD" == "true" ]; then
            continue
        fi

        stage_manifest "$FILENAME" || return 1
    done
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

# Make sure the manifests directory exists
log_info "Make sure that '$K3S_MANIFEST_DIR/' is initialized"
sudo mkdir -p "$K3S_MANIFEST_DIR/"
log_okay "Confirmed that '$K3S_MANIFEST_DIR/' has been initialized"

# Ordered head first (Kyverno, then karpenter-crd), then everything else at once
stage_kyverno_first || {
    log_fail "Failed to stage Kyverno ahead of the other components"
    exit 1
}

stage_karpenter_crd_first || {
    log_fail "Failed to stage karpenter-crd ahead of the main karpenter chart"
    exit 1
}

# Built-in service prep that must precede staging (see the function comments)
prep_longhorn_disk_annotations || {
    log_fail "Failed to set the Longhorn disk annotations"
    exit 1
}

stage_remaining_manifests || {
    log_fail "Failed to stage the remaining manifests"
    exit 1
}

log_okay "$0: COMPLETED"
