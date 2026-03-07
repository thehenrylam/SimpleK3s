#!/bin/bash

# Set bash flags 
set -euo pipefail 
# -u            : Error if an unset variable is referenced 
# -e            : Exits on ANY command failure 
# -o pipefail   : Make pipeline fail if any command in them fails 

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Retrieve the common functions from common.sh (Calls upon simplek3s.env file)
source "$SCRIPT_DIR/lib/common.sh"

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

function wait_for_traefik_middleware() {
    log_info "Waiting for traefik middleware to be ready"

    log_info "Waiting for traefik middleware to be ready"
    wait_for_cmd_3min sudo kubectl -n kube-system get middleware https-redirect || {
        log_fail "traefik middleware never appeared"
        return 1
    }

    log_info "Waiting for traefik ingressroute to be ready"
    wait_for_cmd_3min sudo kubectl -n kube-system get ingressroute web-http-catchall-redirect || {
        log_fail "traefik ingressroute never appeared"
        return 1
    }

    log_info "traefik middleware is ready!"
}

function apply_traefik() {
    log_info "Writing Traefik manifest"

    # Make sure the manifests directory exists
    log_info "Make sure that '$K3S_MANIFEST_DIR/' is initialized"
    sudo mkdir -p "$K3S_MANIFEST_DIR/" || return 1
    log_okay "Confirmed that '$K3S_MANIFEST_DIR/' has been initialized"

    # Transfer the Traefik file to the /var/lib/rancher/k3s/server/manifests/ folder
    local PENDING_FILEPATH="$SCRIPT_DIR/manifests/traefik-helmchart.yaml"
    # We need to set MANIFEST_FILEPATH to traefik-helmchart.yaml to allow K3s to recognize it (traefik.yaml is ignored in K3s if its disabled)
    local MANIFEST_FILEPATH="$K3S_MANIFEST_DIR/traefik-helmchart.yaml"
    log_info "Apply Traefik to $MANIFEST_FILEPATH"
    sudo cp "$PENDING_FILEPATH" "$MANIFEST_FILEPATH" || return 1
    log_okay "Traefik written to $MANIFEST_FILEPATH"

    log_okay "Wrote Traefik manifest"
}

# sudo cp /opt/simplek3s/bootstrap/default/lib/..//manifests/traefik.yaml /var/lib/rancher/k3s/server/manifests/traefik.yaml

function apply_traefik_middleware() {
    log_info "Writing Traefik Middleware manifest"

    # Make sure the manifests directory exists
    log_info "Make sure that '$K3S_MANIFEST_DIR/' is initialized"
    sudo mkdir -p "$K3S_MANIFEST_DIR/" || return 1
    log_okay "Confirmed that '$K3S_MANIFEST_DIR/' has been initialized"

    # Transfer the Traefik manifest file to the /var/lib/rancher/k3s/server/manifests/ folder
    local PENDING_FILEPATH="$SCRIPT_DIR/manifests/traefik-middleware.yaml"
    local MANIFEST_FILEPATH="$K3S_MANIFEST_DIR/traefik-middleware.yaml"
    log_info "Apply Traefik Middleware to $MANIFEST_FILEPATH"
    sudo cp "$PENDING_FILEPATH" "$MANIFEST_FILEPATH" || return 1
    log_okay "Traefik Middleware written to $MANIFEST_FILEPATH"

    log_okay "Wrote Traefik Middleware manifest"
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

apply_traefik || {
    log_fail "Failed to apply Traefik"
    exit 1
}

apply_traefik_middleware || {
    log_fail "Failed to apply Traefik (Middleware)"
    exit 1
}

wait_for_traefik || {
    log_fail "Unable to confirm that Traefik is ready"
    exit 1
}

wait_for_traefik_middleware || {
    log_fail "Unable to confirm that Traefik (Middleware) is ready"
    exit 1
}

log_okay "$0: COMPLETED"


