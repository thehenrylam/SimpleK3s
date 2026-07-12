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
# (e.g. karpenter-nodepool, traefik-middleware, tailscale-ingress) converge on
# their own once their dependency is up.
#
# The ONE ordering exception is Kyverno: its admission webhooks must be in place
# before any other component is admitted, so baseline policies cover the whole
# platform. Kyverno is staged first and gated on readiness; everything else is
# staged in a single pass afterwards.
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

function stage_remaining_manifests() {
    local PENDING_FILEPATH
    local FILENAME
    local IS_KYVERNO
    local KYVERNO_FILENAME

    for PENDING_FILEPATH in "$PENDING_MANIFEST_DIR"/*.yaml; do
        # No manifests at all (glob did not expand)
        [ -e "$PENDING_FILEPATH" ] || continue

        FILENAME="$(basename "$PENDING_FILEPATH")"

        # Skip the Kyverno manifests (already staged by stage_kyverno_first)
        IS_KYVERNO="false"
        for KYVERNO_FILENAME in "${KYVERNO_MANIFESTS[@]}"; do
            if [ "$FILENAME" == "$KYVERNO_FILENAME" ]; then
                IS_KYVERNO="true"
                break
            fi
        done
        if [ "$IS_KYVERNO" == "true" ]; then
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

# Kyverno first (the single ordered exception), then everything else at once
stage_kyverno_first || {
    log_fail "Failed to stage Kyverno ahead of the other components"
    exit 1
}

stage_remaining_manifests || {
    log_fail "Failed to stage the remaining manifests"
    exit 1
}

log_okay "$0: COMPLETED"
