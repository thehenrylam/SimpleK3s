#!/bin/bash

# Set bash flags 
set -euo pipefail 
# -u            : Error if an unset variable is referenced 
# -e            : Exits on ANY command failure 
# -o pipefail   : Make pipeline fail if any command in them fails 

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Retrieve the common functions from common.sh (Calls upon simplek3s.env file)
source "$SCRIPT_DIR/lib/common.sh"

function wait_external_secrets() {
    local NS="external-secrets"
    local DEPLOY_NAME="external-secrets"

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
    wait_for_cmd_5min sudo kubectl -n "$NS" rollout status "deploy/$DEPLOY_NAME" --timeout=10s || {
        log_fail "deployment '$DEPLOY_NAME' not ready"
        sudo kubectl -n "$NS" describe deploy "$DEPLOY_NAME" || true
        sudo kubectl -n "$NS" get pods -o wide || true
        return 1
    }

    # CRDs installed by External Secrets Operator (installCRDs: true)
    # Common CRDs include:
    # - externalsecrets.external-secrets.io
    # - secretstores.external-secrets.io
    # - clustersecretstores.external-secrets.io
    log_info "Checking External Secrets CRDs exist..."
    wait_for_cmd_3min sudo kubectl get crd externalsecrets.external-secrets.io || {
        log_fail "CRD externalsecrets.external-secrets.io missing"
        return 1
    }
    wait_for_cmd_3min sudo kubectl get crd secretstores.external-secrets.io || {
        log_fail "CRD secretstores.external-secrets.io missing"
        return 1
    }
    wait_for_cmd_3min sudo kubectl get crd clustersecretstores.external-secrets.io || {
        log_fail "CRD clustersecretstores.external-secrets.io missing"
        return 1
    }
}

function apply_external_secrets() {
    log_info "Writing External Secrets manifest"

    # Make sure the manifests directory exists
    log_info "Make sure that '$K3S_MANIFEST_DIR/' is initialized"
    sudo mkdir -p "$K3S_MANIFEST_DIR/" || return 1
    log_okay "Confirmed that '$K3S_MANIFEST_DIR/' has been initialized"

    # Transfer the External Secrets file to the /var/lib/rancher/k3s/server/manifests/ folder
    TRAEFIK_PENDING_FILEPATH="$SCRIPT_DIR/manifests/external-secrets.yaml"
    TRAEFIK_MANIFEST_FILEPATH="$K3S_MANIFEST_DIR/external-secrets.yaml"
    log_info "Apply External Secrets to $TRAEFIK_MANIFEST_FILEPATH"
    sudo cp "$TRAEFIK_PENDING_FILEPATH" "$TRAEFIK_MANIFEST_FILEPATH" || return 1
    log_okay "External Secrets written to $TRAEFIK_MANIFEST_FILEPATH"

    log_okay "Wrote External Secrets manifest"
}

log_info "$0: LAUNCHED"

wait_for_k3s_api || {
    log_fail "Unable to confirm that K3s API is ready"
}

wait_for_kubesystem || {
    log_fail "Unable to confirm that Kubesystem is ready"
    exit 1
}

apply_external_secrets || {
    log_fail "Failed to apply External Secrets"
    exit 1
}

wait_external_secrets || {
    log_fail "Unable to confirm that External Secrets is ready"
    exit 1
}

log_okay "$0: COMPLETED"


