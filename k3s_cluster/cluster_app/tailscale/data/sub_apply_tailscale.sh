#!/bin/bash

# Set bash flags
set -euo pipefail
# -u            : Error if an unset variable is referenced
# -e            : Exits on ANY command failure
# -o pipefail   : Make pipeline fail if any command in them fails

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Retrieve the common functions from common.sh (Calls upon simplek3s.env file)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

function apply_tailscale() {
    log_info "Writing Tailscale manifest"

    # Make sure the manifests directory exists
    log_info "Make sure that '$K3S_MANIFEST_DIR/' is initialized"
    sudo mkdir -p "$K3S_MANIFEST_DIR/" || return 1
    log_okay "Confirmed that '$K3S_MANIFEST_DIR/' has been initialized"

    # Transfer the Tailscale file to the /var/lib/rancher/k3s/server/manifests/ folder
    local PENDING_FILEPATH="$SCRIPT_DIR/manifests/tailscale-helmchart.yaml"
    local MANIFEST_FILEPATH="$K3S_MANIFEST_DIR/tailscale-helmchart.yaml"
    log_info "Apply Tailscale to $MANIFEST_FILEPATH"
    sudo cp "$PENDING_FILEPATH" "$MANIFEST_FILEPATH" || return 1
    log_okay "Tailscale written to $MANIFEST_FILEPATH"

    log_okay "Wrote Tailscale manifest"
}

function wait_for_tailscale() {
    local NS="tailscale"
    local DEPLOY_NAME="operator"

    log_info "Waiting for namespace '$NS' to be present..."
    wait_for_cmd_3min sudo kubectl get ns "$NS" || {
        log_fail "namespace '$NS' never appeared"
        return 1
    }

    log_info "Waiting for deployment '$DEPLOY_NAME' to be present..."
    wait_for_cmd_5min sudo kubectl -n "$NS" get deploy "$DEPLOY_NAME" || {
        log_fail "deployment '$DEPLOY_NAME' never appeared in namespace '$NS'"
        sudo kubectl -n "$NS" get all || true
        return 1
    }

    log_info "Waiting for deployment '$DEPLOY_NAME' to be ready..."
    wait_for_cmd_5min sudo kubectl -n "$NS" rollout status "deploy/$DEPLOY_NAME" --timeout=10s || {
        log_fail "deployment '$DEPLOY_NAME' not ready"
        sudo kubectl -n "$NS" describe deploy "$DEPLOY_NAME" || true
        sudo kubectl -n "$NS" get pods -o wide || true
        return 1
    }

    # The operator registers the `tailscale` IngressClass that internal-exposure
    # apps reference. Confirm it exists before applications are applied.
    log_info "Checking the 'tailscale' IngressClass exists..."
    wait_for_cmd_3min sudo kubectl get ingressclass tailscale || {
        log_fail "IngressClass 'tailscale' missing"
        return 1
    }
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

apply_tailscale || {
    log_fail "Failed to apply Tailscale"
    exit 1
}

wait_for_tailscale || {
    log_fail "Unable to confirm that Tailscale is ready"
    exit 1
}

log_okay "$0: COMPLETED"
