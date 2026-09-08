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

STAGED_CHANGED=0
STAGED_TOTAL=0
STAGED_FILES=""

function stage_manifest() {
    local FILENAME="$1"
    local PENDING_FILEPATH="$PENDING_MANIFEST_DIR/$FILENAME"
    local MANIFEST_FILEPATH="$K3S_MANIFEST_DIR/$FILENAME"

    STAGED_TOTAL=$((STAGED_TOTAL + 1))

    # Compare before copying. The unconditional cp emitted two log lines per
    # manifest regardless, so a run that changed one file and a run that changed
    # none produced byte-identical output — it reported effort, not change.
    # A missing destination makes cmp fail, which is correctly "changed".
    if sudo cmp -s "$PENDING_FILEPATH" "$MANIFEST_FILEPATH" 2>/dev/null; then
        return 0
    fi

    log_info "Staging manifest '$FILENAME' to $MANIFEST_FILEPATH"
    sudo cp "$PENDING_FILEPATH" "$MANIFEST_FILEPATH" || return 1
    STAGED_CHANGED=$((STAGED_CHANGED + 1))
    STAGED_FILES="${STAGED_FILES}${FILENAME}"$'\n'
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
        pull_report_kv step action name longhorn_node_annotations performed false \
            detail "no pools configured"
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
        pull_report_kv step action name longhorn_node_annotations performed false \
            detail "no nodes match any pool"
        return 0
    fi

    local NODE ANNOTATION
    local ANNOTATED=0
    while IFS=$'\t' read -r NODE ANNOTATION; do
        [ -z "$NODE" ] && continue

        ANNOTATED=$((ANNOTATED + 1))
        log_info "Node '$NODE': setting longhorn.io/default-disks-annotation"
        sudo kubectl annotate node "$NODE" \
            "longhorn.io/default-disks-annotation=$ANNOTATION" \
            --overwrite || {
            log_fail "Node '$NODE': failed to set longhorn.io/default-disks-annotation"
            return 1
        }
    done <<< "$NODE_ANNOTATIONS"

    pull_report_kv step action name longhorn_node_annotations performed true \
        detail "annotated ${ANNOTATED} node(s) with their disk configuration"
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


# What the CLUSTER has applied, versus what S3 delivered.
#
# The staged-file comparison in stage_manifest answers "did this node need to
# write the file" — a per-node disk question. On a node that has never staged,
# every manifest reads as changed even when the cluster is happily running all
# of them, which is how a pull could report "15 of 15 changed" about a cluster
# where nothing was wrong (#144).
#
# The deploy controller records a sha256 of every manifest it ingested on the
# Addon object, in etcd. Comparing against that gives the same answer from any
# node. Matching is by spec.source (the staged path) rather than by Addon name,
# so no assumption is made about how k3s derives names from filenames.
#
# Measured BEFORE staging, so it describes the cluster as it stands rather than
# what it is about to become.
#
# This says the controller INGESTED the content, not that the resources are
# healthy — an Addon can carry the current checksum while its HelmChart fails.
# Health is what `sk3s status` answers.
#
# Orphans (Addons with no pending manifest) are deliberately NOT reported here.
# K3s ships its own bundled manifests — ccm, coredns, local-storage,
# rolebindings, runtimes and the metrics-server set — which have no pending file
# either, so a naive orphan count would flag coredns as abandoned. Doing it
# properly needs a way to tell our manifests from k3s's, which belongs to #151.
function report_cluster_state() {
    local _ADDONS _SOURCE _SUM _PENDING _FILENAME _STAGED_PATH _LOCAL
    local _CURRENT=0 _DIFFERS=0 _MISSING=0 _DIFF_FILES=""
    # Node-side bash is 5.x (Debian), so associative arrays are available here.
    # The host-side scripts cannot use them — macOS ships bash 3.2.
    local -A _CLUSTER_SUM

    _ADDONS="$(sudo kubectl get addons -A \
        -o jsonpath='{range .items[*]}{.spec.source}{"\t"}{.spec.checksum}{"\n"}{end}' 2>/dev/null)" || {
        log_warn "Could not read Addon checksums; cluster comparison unavailable"
        pull_report_kv step cluster result unknown detail "could not read Addon checksums"
        return 0
    }

    if [[ -z "${_ADDONS}" ]]; then
        # No Addons at all is not "everything matches" — it means we learned
        # nothing. Reporting 0 differences here would read as a healthy cluster.
        log_warn "No Addons returned; cluster comparison unavailable"
        pull_report_kv step cluster result unknown detail "no Addons returned"
        return 0
    fi

    while IFS=$'\t' read -r _SOURCE _SUM; do
        [[ -n "${_SOURCE}" ]] || continue
        _CLUSTER_SUM["${_SOURCE}"]="${_SUM}"
    done <<< "${_ADDONS}"

    for _PENDING in "$PENDING_MANIFEST_DIR"/*.yaml; do
        [ -e "$_PENDING" ] || continue
        _FILENAME="$(basename "$_PENDING")"
        _STAGED_PATH="$K3S_MANIFEST_DIR/$_FILENAME"
        _LOCAL="$(sha256sum "$_PENDING" | cut -d' ' -f1)"

        if [[ -z "${_CLUSTER_SUM[$_STAGED_PATH]:-}" ]]; then
            _MISSING=$((_MISSING + 1))
            _DIFF_FILES="${_DIFF_FILES}${_FILENAME} (not applied)"$'\n'
        elif [[ "${_CLUSTER_SUM[$_STAGED_PATH]}" == "${_LOCAL}" ]]; then
            _CURRENT=$((_CURRENT + 1))
        else
            _DIFFERS=$((_DIFFERS + 1))
            _DIFF_FILES="${_DIFF_FILES}${_FILENAME}"$'\n'
        fi
    done

    log_info "Cluster: ${_CURRENT} current, ${_DIFFERS} differ, ${_MISSING} not applied"
    pull_report_kv step cluster result ok current "${_CURRENT}" differs "${_DIFFERS}" \
        missing "${_MISSING}" files "$(printf '%s' "${_DIFF_FILES}" | json_array)"
}

# Count what staging WOULD change, then stop. Deliberately placed before the
# readiness gates: those exist to sequence real staging, and prep_longhorn_disk_
# annotations mutates node annotations, so a preview must not reach any of it.
function dry_run_scan() {
    local PENDING_FILEPATH FILENAME
    for PENDING_FILEPATH in "$PENDING_MANIFEST_DIR"/*.yaml; do
        [ -e "$PENDING_FILEPATH" ] || continue
        FILENAME="$(basename "$PENDING_FILEPATH")"
        STAGED_TOTAL=$((STAGED_TOTAL + 1))
        if sudo cmp -s "$PENDING_FILEPATH" "$K3S_MANIFEST_DIR/$FILENAME" 2>/dev/null; then
            continue
        fi
        STAGED_CHANGED=$((STAGED_CHANGED + 1))
        STAGED_FILES="${STAGED_FILES}${FILENAME}"$'\n'
    done
    log_info "DRY RUN: ${STAGED_CHANGED} of ${STAGED_TOTAL} manifests would change"
    pull_report_kv step stage result ok changed "${STAGED_CHANGED}" total "${STAGED_TOTAL}" \
        files "$(printf '%s' "${STAGED_FILES}" | json_array)"
}

log_info "$0: LAUNCHED"

if is_dry_run; then
    report_cluster_state
    dry_run_scan
    log_okay "$0: COMPLETED (dry run — nothing changed)"
    exit 0
fi

wait_for_k3s_api || {
    log_fail "Unable to confirm that K3s API is ready"
    exit 1
}

wait_for_kubesystem || {
    log_fail "Unable to confirm that Kubesystem is ready"
    exit 1
}

# Cluster comparison before anything is written, so it reports the state being
# changed FROM rather than the state left behind.
report_cluster_state

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
    pull_report_kv step stage result failed changed "${STAGED_CHANGED}" total "${STAGED_TOTAL}"
    exit 1
}

log_info "Manifests: ${STAGED_CHANGED} changed of ${STAGED_TOTAL}"
pull_report_kv step stage result ok changed "${STAGED_CHANGED}" total "${STAGED_TOTAL}" \
    files "$(printf '%s' "${STAGED_FILES}" | json_array)"

log_okay "$0: COMPLETED"
