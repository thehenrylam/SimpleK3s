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
    wait_for_cmd_3min sudo kubectl -n "$NS" rollout status deployment --timeout=10s || {
        log_fail "deployment '$DEPLOY_NAME' not ready"
        sudo kubectl -n "$NS" describe deploy "$DEPLOY_NAME" || true
        sudo kubectl -n "$NS" get pods -o wide || true
        return 1
    }

    ESO_FULLNAME="externalsecret/argocd-oidc-into-argocd-secret"

    log_info "Waiting for secret manager '$ESO_FULLNAME' to be present..."
    wait_for_cmd_3min sudo kubectl -n "$NS" wait "$ESO_FULLNAME" --for=condition=Ready=True --timeout=10s || {
        log_fail "secret manager '$ESO_FULLNAME' never appeared in namespace '$NS'"
        sudo kubectl -n "$NS" get all || true
        return 1
    }

    # Ready=True alone is a false positive (a Merge ExternalSecret parks at SecretMissing
    # but still reports Ready). Assert the OIDC value actually landed in the secret before
    # proceeding. jsonpath avoids a jq dependency; the base64 value just needs to be non-empty.
    local OIDC_SECRET="argocd-oidc"
    log_info "Asserting OIDC issuer value is populated in secret '$OIDC_SECRET'..."
    wait_for_cmd_3min bash -c "sudo kubectl -n '$NS' get secret '$OIDC_SECRET' --ignore-not-found -o jsonpath='{.data.oidc\.cognito\.issuer}' | grep -q ." || {
        log_fail "secret '$OIDC_SECRET' has empty 'oidc.cognito.issuer' — ESO did not sync the OIDC config"
        sudo kubectl -n "$NS" describe externalsecret argocd-oidc-into-argocd-secret || true
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
    local PENDING_FILEPATH="$SCRIPT_DIR/manifests/argocd.yaml"
    local MANIFEST_FILEPATH="$K3S_MANIFEST_DIR/argocd.yaml"
    log_info "Apply ArgoCD module to $MANIFEST_FILEPATH"
    sudo cp "$PENDING_FILEPATH" "$MANIFEST_FILEPATH" || return 1
    log_okay "ArgoCD module written to $MANIFEST_FILEPATH"

    # Wait for ArgoCD to be ready (incl. the assert that argocd-oidc is actually populated)
    wait_argocd || return 1

    # Restart argocd-server now that the OIDC secret is confirmed populated.
    # Why (see #95): argocd-server mounts the /auth/login and /auth/callback OIDC HTTP
    # routes ONCE at startup, and only when SSO resolves as configured at that instant.
    # On a fresh deploy it boots before ESO populates the argocd-oidc secret, so SSO looks
    # unconfigured and those routes are never registered (they 404 — the SSO button
    # dead-ends on a blank page). Token validation reloads from settings live, but the
    # HTTP mux does not, so only a restart re-registers the routes. The value-assert in
    # wait_argocd() above guarantees the secret is present before we restart here.
    # Only argocd-server matters; the repo-server/redis do not gate OIDC route registration.
    # Readiness after the restart is re-validated by the wait_argocd() call that main()
    # runs right after apply_argocd() returns: its `rollout status deployment` step blocks
    # on the new ReplicaSet (rollout restart bumps the deployment generation), so we don't
    # repeat that check here.
    log_info "Restarting argocd-server so it registers OIDC routes against the synced secret"
    sudo kubectl -n argocd rollout restart deployment argocd-server || return 1
    log_okay "argocd-server restart requested (readiness re-checked by wait_argocd)"

    log_okay "Applied ArgoCD module"
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

apply_argocd || {
    log_fail "Failed to apply ArgoCD"
    exit 1
}

wait_argocd || {
    log_fail "Unable to confirm that ArgoCD is ready"
    exit 1
}

log_okay "$0: COMPLETED"
