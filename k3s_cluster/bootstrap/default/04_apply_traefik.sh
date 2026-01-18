#!/bin/bash

# Set bash flags 
set -euo pipefail 
# -u            : Error if an unset variable is referenced 
# -e            : Exits on ANY command failure 
# -o pipefail   : Make pipeline fail if any command in them fails 

SCRIPT_DIR=$(realpath $(dirname $0))

# Retrieve all of the needed environment variables from this file
source "$SCRIPT_DIR/simplek3s.env"
# Retrieve the common functions from common.sh
source "$SCRIPT_DIR/common.sh"
# Retrieve the common functions from common_aws.sh
source "$SCRIPT_DIR/common_aws.sh"

# Wait for Traefik to be ready (so that we can customize it afterwards)
function wait_for_traefik() {
    log_info "Waiting for traefik to be ready"

    log_info "Waiting for traefik helm install job exists..."
    wait_for_cmd_3min sudo kubectl -n kube-system get job helm-install-traefik || {
        log_fail "helm-install-traefik job never appeared"
        return 1
    }

    log_info "Waiting for traefik helm install job complete..."
    wait_for_cmd_1min sudo kubectl -n kube-system wait --for=condition=complete job/helm-install-traefik --timeout=10s || {
        log_fail "helm-install-traefik job did not complete"
        return 1
    }

    log_info "Waiting for traefik deployment to be present..."
    wait_for_cmd_3min sudo kubectl -n kube-system get deploy traefik || {
        log_fail "traefik deployment never appeared"
        return 1
    }

    log_info "Waiting for traefik deployment to be ready..."
    wait_for_cmd_1min sudo kubectl -n kube-system rollout status deploy/traefik --timeout=10s || {
        log_fail "traefik deployment not ready"
        return 1
    }

    log_okay "traefik is ready!"
}

function apply_traefik() {
    log_info "Writing Traefik HelmChartConfig manifest"

    # Make sure the manifests directory exists
    log_info "Make sure that '$K3S_MANIFEST_DIR/' is initialized"
    sudo mkdir -p "$K3S_MANIFEST_DIR/" || return 1
    log_okay "Confirmed that '$K3S_MANIFEST_DIR/' has been initialized"

    # Transfer the Traefik manifest file to the /var/lib/rancher/k3s/server/manifests/ folder
    TRAEFIK_PENDING_FILEPATH="$SCRIPT_DIR/manifests/traefik-config.yaml"
    TRAEFIK_MANIFEST_FILEPATH="$K3S_MANIFEST_DIR/traefik-config.yaml"
    log_info "Apply Traefik HelmChartConfig to $TRAEFIK_MANIFEST_FILEPATH"
    sudo cp "$TRAEFIK_PENDING_FILEPATH" "$TRAEFIK_MANIFEST_FILEPATH" || return 1
    log_okay "Traefik HelmChartConfig written to $TRAEFIK_MANIFEST_FILEPATH"

    log_okay "Wrote Traefik HelmChartConfig manifest"
}

log_info "$0: LAUNCHED"

wait_for_k3s_api || {
    log_fail "Unable to confirm that K3s API is ready"
}

wait_for_kubesystem || {
    log_fail "Unable to confirm that Kubesystem is ready"
    exit 1
}

wait_for_traefik || {
    log_fail "Unable to confirm that Traefik is ready"
    exit 1
}

apply_traefik || {
    log_fail "Failed to apply Traefik"
    exit 1
}

log_okay "$0: COMPLETED"


