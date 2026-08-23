#!/bin/bash

# Set bash flags
set -euo pipefail
# -u            : Error if an unset variable is referenced
# -e            : Exits on ANY command failure
# -o pipefail   : Make pipeline fail if any command in them fails

# Post-staging imperative actions.
#
# After bts_05_stage_manifests.sh stages every manifest, the cluster converges
# on its own (level-triggered reconciliation). The exceptions live here: actions
# that are genuinely imperative because the target component does NOT reconcile
# them by itself. Each action is guarded on its component's manifest being
# staged, and carries only the waits its own action needs.
#
# Current actions:
#   - Longhorn disk registration: Longhorn reads the default-disks annotation
#     only when it first discovers a node; existing nodes.longhorn.io objects
#     with empty disks are never re-read, so we patch them directly.
#   - ArgoCD OIDC route restart (#95): argocd-server registers its OIDC HTTP
#     routes ONCE at startup. On a fresh deploy it boots before External-Secrets
#     populates the argocd-oidc secret, so the routes 404 until a restart.
#   - Tailscale entrypoint reconcile (#126): the operator's ingress-reconciler
#     gives up permanently if it sees the tailnet-entrypoint Ingress before its
#     ProxyClass is Ready, which is the normal cold-boot ordering. Nothing
#     re-triggers it, so the proxy device is never created.
#
# Long term these should become in-cluster Jobs (or upstream fixes) so this
# file can be deleted.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Retrieve the common functions from common.sh (Calls upon simplek3s.env file)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

PENDING_MANIFEST_DIR="$SCRIPT_DIR/manifests"

##################################################
#   Longhorn : register disks from annotations   #
##################################################

function wait_longhorn_node_crs() {
    # Wait for the Longhorn manager to exist and to have discovered every node
    # (a nodes.longhorn.io object per Kubernetes node). Under convergence the
    # Longhorn install may still be in flight when this runs.
    log_info "Waiting for the nodes.longhorn.io CRD..."
    wait_for_cmd_5min sudo kubectl get crd nodes.longhorn.io || {
        log_fail "CRD nodes.longhorn.io never appeared (Longhorn did not converge)"
        return 1
    }

    local NODES
    NODES="$(sudo kubectl get nodes -o jsonpath='{.items[*].metadata.name}')"

    local NODE
    for NODE in $NODES; do
        log_info "Waiting for nodes.longhorn.io object for node '$NODE'..."
        wait_for_cmd_5min sudo kubectl -n longhorn-system get nodes.longhorn.io "$NODE" || {
            log_fail "Longhorn never discovered node '$NODE'"
            sudo kubectl -n longhorn-system get nodes.longhorn.io || true
            return 1
        }
    done

    log_okay "Longhorn has discovered all nodes."
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

function converge_action_longhorn() {
    if [ ! -f "$PENDING_MANIFEST_DIR/longhorn.yaml" ]; then
        log_info "No Longhorn manifest staged; skipping Longhorn disk registration"
        return 0
    fi

    wait_longhorn_node_crs || return 1
    register_longhorn_disks || return 1
}

##################################################
#   ArgoCD : restart server for OIDC routes      #
##################################################

function converge_action_argocd() {
    if [ ! -f "$PENDING_MANIFEST_DIR/argocd.yaml" ]; then
        log_info "No ArgoCD manifest staged; skipping ArgoCD OIDC restart"
        return 0
    fi

    local NS="argocd"
    local DEPLOY_NAME="argocd-server"

    log_info "Waiting for deployment '$DEPLOY_NAME' to be present..."
    wait_for_cmd_5min sudo kubectl -n "$NS" get deploy "$DEPLOY_NAME" || {
        log_fail "deployment '$DEPLOY_NAME' never appeared (ArgoCD did not converge)"
        sudo kubectl -n "$NS" get all || true
        return 1
    }

    # Ready=True alone is a false positive (a Merge ExternalSecret parks at SecretMissing
    # but still reports Ready). Assert the OIDC value actually landed in the secret before
    # restarting. jsonpath avoids a jq dependency; the base64 value just needs to be non-empty.
    local OIDC_SECRET="argocd-oidc"
    log_info "Waiting for OIDC issuer value to be populated in secret '$OIDC_SECRET'..."
    wait_for_cmd_5min bash -c "sudo kubectl -n '$NS' get secret '$OIDC_SECRET' --ignore-not-found -o jsonpath='{.data.oidc\.cognito\.issuer}' | grep -q ." || {
        log_fail "secret '$OIDC_SECRET' has empty 'oidc.cognito.issuer' — ESO did not sync the OIDC config"
        sudo kubectl -n "$NS" describe externalsecret argocd-oidc-into-argocd-secret || true
        return 1
    }

    # Why (see #95): argocd-server mounts the /auth/login and /auth/callback OIDC HTTP
    # routes ONCE at startup, and only when SSO resolves as configured at that instant.
    # On a fresh deploy it boots before ESO populates the argocd-oidc secret, so SSO looks
    # unconfigured and those routes are never registered (they 404 — the SSO button
    # dead-ends on a blank page). Token validation reloads from settings live, but the
    # HTTP mux does not, so only a restart re-registers the routes.
    log_info "Restarting argocd-server so it registers OIDC routes against the synced secret"
    sudo kubectl -n "$NS" rollout restart deployment "$DEPLOY_NAME" || return 1

    log_info "Waiting for '$DEPLOY_NAME' to be ready after the restart..."
    wait_for_cmd_3min sudo kubectl -n "$NS" rollout status "deploy/$DEPLOY_NAME" --timeout=10s || {
        log_fail "deployment '$DEPLOY_NAME' not ready after restart"
        sudo kubectl -n "$NS" get pods -o wide || true
        return 1
    }

    log_okay "argocd-server restarted with OIDC routes registered"
}

##################################################
#  Tailscale : reconcile the tailnet entrypoint  #
##################################################

function converge_action_tailscale() {
    if [ ! -f "$PENDING_MANIFEST_DIR/tailscale-ingress.yaml" ]; then
        log_info "No Tailscale ingress manifest staged; skipping Tailscale entrypoint reconcile"
        return 0
    fi

    local NS="tailscale"
    local DEPLOY_NAME="operator"
    local INGRESS_NAME="tailnet-entrypoint"
    local SEL="tailscale.com/parent-resource=${INGRESS_NAME},tailscale.com/parent-resource-type=ingress"
    local HAS_PROXY="sudo kubectl -n $NS get statefulset -l $SEL -o name 2>/dev/null | grep -q ."

    log_info "Waiting for deployment '$DEPLOY_NAME' to be present..."
    wait_for_cmd_5min sudo kubectl -n "$NS" get deploy "$DEPLOY_NAME" || {
        log_fail "deployment '$DEPLOY_NAME' never appeared (Tailscale operator did not converge)"
        sudo kubectl -n "$NS" get all || true
        return 1
    }

    # The Ingress lives in Traefik's namespace (an Ingress backend is same-namespace),
    # which is configurable via traefik_backend — look it up by name across namespaces
    # rather than hardcoding one.
    log_info "Waiting for the '$INGRESS_NAME' Ingress to be applied..."
    wait_for_cmd_5min bash -c "sudo kubectl get ingress -A --field-selector metadata.name='$INGRESS_NAME' -o name 2>/dev/null | grep -q ." || {
        log_fail "Ingress '$INGRESS_NAME' never appeared (its manifest did not apply)"
        return 1
    }

    log_info "Waiting for the Tailscale ProxyClass to be Ready..."
    wait_for_cmd_5min sudo kubectl wait --for=condition=ProxyClassReady proxyclass --all --timeout=10s || {
        log_fail "No Tailscale ProxyClass reached Ready"
        sudo kubectl get proxyclass -o wide || true
        return 1
    }

    # Give the operator a fair chance to reconcile on its own before intervening: when it
    # wins its own startup race (see below) the proxy appears within seconds of the
    # ProxyClass going Ready. Only a stuck operator should ever be restarted.
    if wait_for_cmd_1min bash -c "$HAS_PROXY"; then
        log_okay "Tailscale proxy for '$INGRESS_NAME' exists; no restart needed"
        return 0
    fi

    # Why (see #126): the operator's ingress-reconciler and proxyclass-reconciler start in
    # the same instant on a cold boot. The Ingress is already in etcd by then, so the
    # ingress-reconciler runs first, finds the ProxyClass not yet Ready, logs
    # "not (yet) Ready, waiting.." and returns. Its sibling marks the ProxyClass Ready
    # moments later, but that transition does not re-trigger the ingress-reconciler
    # (operator v1.98.4) — so the Ingress is never reconciled and no tailnet device is
    # created. Staging cannot fix this: the Ingress applied cleanly on the first attempt,
    # so the K3s deploy controller has nothing to retry. Restarting is what breaks the
    # deadlock, because on the second boot the ProxyClass is ALREADY Ready and the very
    # first reconcile pass succeeds.
    log_info "No proxy StatefulSet for '$INGRESS_NAME'; restarting the operator to force a re-reconcile"
    sudo kubectl -n "$NS" rollout restart deployment "$DEPLOY_NAME" || return 1

    log_info "Waiting for '$DEPLOY_NAME' to be ready after the restart..."
    wait_for_cmd_3min sudo kubectl -n "$NS" rollout status "deploy/$DEPLOY_NAME" --timeout=10s || {
        log_fail "deployment '$DEPLOY_NAME' not ready after restart"
        sudo kubectl -n "$NS" get pods -o wide || true
        return 1
    }

    log_info "Waiting for the proxy StatefulSet for '$INGRESS_NAME'..."
    wait_for_cmd_3min bash -c "$HAS_PROXY" || {
        log_fail "operator created no proxy StatefulSet for '$INGRESS_NAME' after the restart"
        sudo kubectl -n "$NS" logs "deploy/$DEPLOY_NAME" --tail=50 || true
        return 1
    }

    log_okay "Tailscale proxy for '$INGRESS_NAME' created"
}


log_info "$0: LAUNCHED"

wait_for_k3s_api || {
    log_fail "Unable to confirm that K3s API is ready"
    exit 1
}

converge_action_longhorn || {
    log_fail "Failed converge action: Longhorn disk registration"
    exit 1
}

converge_action_argocd || {
    log_fail "Failed converge action: ArgoCD OIDC restart"
    exit 1
}

converge_action_tailscale || {
    log_fail "Failed converge action: Tailscale entrypoint reconcile"
    exit 1
}

log_okay "$0: COMPLETED"
