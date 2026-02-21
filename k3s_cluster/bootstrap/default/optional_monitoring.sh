#!/bin/bash

# Set bash flags 
set -euo pipefail 
# -u            : Error if an unset variable is referenced 
# -e            : Exits on ANY command failure 
# -o pipefail   : Make pipeline fail if any command in them fails 

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Retrieve the common functions from common.sh (Calls upon simplek3s.env file)
source "$SCRIPT_DIR/lib/common.sh"

function wait_generic() {
    local NS="$1"
    local DEPLOY_NAME="$2"

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

function wait_grafana() {
    local NS="monitoring"
    local DEPLOY_NAME="prometheus-grafana"
    wait_generic "${NS}" "${DEPLOY_NAME}" || return 1
}

function wait_prometheus_operator() {
    local NS="monitoring"
    local DEPLOY_NAME="prometheus-kube-prometheus-operator"
    wait_generic "${NS}" "${DEPLOY_NAME}" || return 1
}

function wait_prometheus_metrics() {
    local NS="monitoring"
    local DEPLOY_NAME="prometheus-kube-prometheus-metrics"
    wait_generic "${NS}" "${DEPLOY_NAME}" || return 1
}

function apply_monitoring() {
    log_info "Applying Monitoring module"

    # Make sure the manifests directory exists
    log_info "Make sure that '$K3S_MANIFEST_DIR/' is initialized"
    sudo mkdir -p "$K3S_MANIFEST_DIR/" || return 1
    log_okay "Confirmed that '$K3S_MANIFEST_DIR/' has been initialized"

    # Transfer the Monitoring manifest file to the manifests folder
    TRAEFIK_PENDING_FILEPATH="$SCRIPT_DIR/manifests/monitoring.yaml"
    TRAEFIK_MANIFEST_FILEPATH="$K3S_MANIFEST_DIR/monitoring.yaml"
    log_info "Apply Monitoring module to $TRAEFIK_MANIFEST_FILEPATH"
    sudo cp "$TRAEFIK_PENDING_FILEPATH" "$TRAEFIK_MANIFEST_FILEPATH" || return 1
    log_okay "Monitoring module written to $TRAEFIK_MANIFEST_FILEPATH"

    log_okay "Applied Monitoring module"
}

log_info "$0: LAUNCHED"

wait_for_k3s_api || {
    log_fail "Unable to confirm that K3s API is ready"
}

wait_for_kubesystem || {
    log_fail "Unable to confirm that Kubesystem is ready"
    exit 1
}

apply_monitoring || {
    log_fail "Failed to apply Monitoring"
    exit 1
}

wait_prometheus_operator || {
    log_fail "Unable to confirm that Monitoring (Prometheus Operator) is ready"
    exit 1
}

wait_prometheus_metrics || {
    log_fail "Unable to confirm that Monitoring (Prometheus Metrics) is ready"
    exit 1
}

wait_grafana || {
    log_fail "Unable to confirm that Monitoring (Grafana) is ready"
    exit 1
}

log_okay "$0: COMPLETED"
