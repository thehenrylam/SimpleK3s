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

function wait_for_proxyclass() {
    # The tailnet-entrypoint Ingress inherits the operator-configured ProxyClass
    # (<hostname_prefix>-proxy). If that Ingress is applied before the ProxyClass is
    # Ready, the operator's ingress-reconciler logs "not (yet) Ready, waiting.." and
    # (in operator v1.98.4) never re-reconciles, leaving the proxy device uncreated.
    # Gate the Ingress apply (apply_tailnet_ingress) on this readiness to close that
    # race. Name-agnostic: this cluster has exactly one ProxyClass, so confirm one
    # exists first (a bare `wait --all` would pass on zero matches) then wait on the
    # ProxyClassReady condition.
    log_info "Waiting for the Tailscale ProxyClass to be present..."
    wait_for_cmd_3min bash -c "sudo kubectl get proxyclass -o name | grep -q ." || {
        log_fail "no Tailscale ProxyClass ever appeared"
        sudo kubectl get proxyclass || true
        return 1
    }

    log_info "Waiting for the Tailscale ProxyClass to be Ready..."
    wait_for_cmd_3min sudo kubectl wait --for=condition=ProxyClassReady proxyclass --all --timeout=10s || {
        log_fail "Tailscale ProxyClass did not become Ready"
        sudo kubectl get proxyclass -o wide || true
        return 1
    }
}

function apply_tailnet_ingress() {
    log_info "Writing Tailscale tailnet-entrypoint Ingress manifest"

    # Make sure the manifests directory exists
    log_info "Make sure that '$K3S_MANIFEST_DIR/' is initialized"
    sudo mkdir -p "$K3S_MANIFEST_DIR/" || return 1
    log_okay "Confirmed that '$K3S_MANIFEST_DIR/' has been initialized"

    # Applied only after wait_for_proxyclass so the operator reconciles it once the
    # ProxyClass is already Ready (no ingress-reconciler race).
    local PENDING_FILEPATH="$SCRIPT_DIR/manifests/tailscale-ingress.yaml"
    local MANIFEST_FILEPATH="$K3S_MANIFEST_DIR/tailscale-ingress.yaml"
    log_info "Apply tailnet-entrypoint Ingress to $MANIFEST_FILEPATH"
    sudo cp "$PENDING_FILEPATH" "$MANIFEST_FILEPATH" || return 1
    log_okay "tailnet-entrypoint Ingress written to $MANIFEST_FILEPATH"
}

function wait_for_proxy() {
    local NS="tailscale"
    # Labels the operator stamps on the StatefulSet it creates for the Ingress.
    local SEL="tailscale.com/parent-resource=tailnet-entrypoint,tailscale.com/parent-resource-type=ingress"

    # The operator materializes the tailnet device as a StatefulSet once it
    # reconciles the Ingress. Assert it actually appears and rolls out, so a wedged
    # proxy fails the bootstrap LOUDLY instead of completing with no tailnet device.
    log_info "Waiting for the Tailscale proxy StatefulSet to be created..."
    wait_for_cmd_3min bash -c "sudo kubectl -n '$NS' get statefulset -l '$SEL' -o name | grep -q ." || {
        log_fail "the Tailscale proxy StatefulSet was never created for tailnet-entrypoint"
        sudo kubectl -n "$NS" get statefulset -o wide || true
        sudo kubectl -n "$NS" get pods -o wide || true
        return 1
    }

    log_info "Waiting for the Tailscale proxy StatefulSet to be ready..."
    wait_for_cmd_5min bash -c "sudo kubectl -n '$NS' rollout status \$(sudo kubectl -n '$NS' get statefulset -l '$SEL' -o name) --timeout=10s" || {
        log_fail "the Tailscale proxy StatefulSet did not become ready"
        sudo kubectl -n "$NS" get pods -l "$SEL" -o wide || true
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

wait_for_proxyclass || {
    log_fail "Unable to confirm that the Tailscale ProxyClass is Ready"
    exit 1
}

apply_tailnet_ingress || {
    log_fail "Failed to apply the Tailscale tailnet-entrypoint Ingress"
    exit 1
}

wait_for_proxy || {
    log_fail "Unable to confirm that the Tailscale proxy device was created"
    exit 1
}

log_okay "$0: COMPLETED"
