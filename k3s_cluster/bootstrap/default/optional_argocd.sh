#!/bin/bash

# Set bash flags 
set -euo pipefail 
# -u            : Error if an unset variable is referenced 
# -e            : Exits on ANY command failure 
# -o pipefail   : Make pipeline fail if any command in them fails 

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Retrieve the common functions from common.sh (Calls upon simplek3s.env file)
source "$SCRIPT_DIR/lib/common.sh"

function wait_argocd() {
    local NS="argocd"
    local DEPLOY_NAME="argocd-server"

    log_info "Waiting for namespace '$NS' to be present..."
    wait_for_cmd_3min sudo kubectl get ns "$NS" || {
        log_fail "namespace '$NS' never appeared"
        return 1
    }

    log_info "Waiting for deployment '$DEPLOY_NAME' to be present..."
    wait_for_cmd_3min sudo kubectl -n "$NS" get deploy "$DEPLOY_NAME" || {
        log_fail "deployment '$DEPLOY_NAME' never appeared in namespace '$NS'"
        sudo kubectl -n "$NS" get all || true
        return 1
    }

    log_info "Waiting for deployment '$DEPLOY_NAME' to be ready..."
    wait_for_cmd_3min sudo kubectl -n "$NS" rollout status "deploy/$DEPLOY_NAME" --timeout=10s || {
        log_fail "deployment '$DEPLOY_NAME' not ready"
        sudo kubectl -n "$NS" describe deploy "$DEPLOY_NAME" || true
        sudo kubectl -n "$NS" get pods -o wide || true
        return 1
    }
}

function apply_argocd() {
    log_info "Applying ArgoCD module"

    # Make sure the manifests directory exists
    log_info "Make sure that '$K3S_MANIFEST_DIR/' is initialized"
    sudo mkdir -p "$K3S_MANIFEST_DIR/" || return 1
    log_okay "Confirmed that '$K3S_MANIFEST_DIR/' has been initialized"

    # Transfer the ArgoCD manifest file to the manifests folder
    TRAEFIK_PENDING_FILEPATH="$SCRIPT_DIR/manifests/argocd.yaml"
    TRAEFIK_MANIFEST_FILEPATH="$K3S_MANIFEST_DIR/argocd.yaml"
    log_info "Apply ArgoCD module to $TRAEFIK_MANIFEST_FILEPATH"
    sudo cp "$TRAEFIK_PENDING_FILEPATH" "$TRAEFIK_MANIFEST_FILEPATH" || return 1
    log_okay "ArgoCD module written to $TRAEFIK_MANIFEST_FILEPATH"

    # Wait for ArgoCD to be ready
    wait_argocd || return 1

    # Additional wait time to 15 seconds
    sleep 15

    # Re-roll the rollout of the ArgoCD module 
    # Why: 
    #   - This is to help work around a weird issue with the argocd.yaml file
    #   - The weird issue is where the SecretStore variables won't properly template unless it rolls out a second time
    #   - Likely due to an ordering issue; Multiple attempts to order the installation didn't solve it (We'll check back on it at a later date)
    log_info "Restarting rollout of the ArgoCD module"
    sudo kubectl -n argocd rollout restart deploy/argocd-server
    log_okay "Completed rollout of the ArgoCD module"

    log_okay "Applied ArgoCD module"
}

log_info "$0: LAUNCHED"

wait_for_k3s_api || {
    log_fail "Unable to confirm that K3s API is ready"
}

wait_for_kubesystem || {
    log_fail "Unable to confirm that Kubesystem is ready"
    exit 1
}

apply_argocd || {
    log_fail "Failed to apply ArgoCD"
    exit 1
}

wait_argocd || {
    log_fail "Unable to confirm that ArgoCD is ready"
    exit 1
}

log_okay "$0: COMPLETED"
