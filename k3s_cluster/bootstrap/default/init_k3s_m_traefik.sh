#!/bin/bash

# Set bash flags 
set -euo pipefail 
# -u            : Error if an unset variable is referenced 
# -e            : Exits on ANY command failure 
# -o pipefail   : Make pipeline fail if any command in them fails 

# Expected directory    : <root_dir>/bootstrap/default/
# Expected utils script : <root_dir>/bootstrap/init_utils.sh
SCRIPT_DIR=$(dirname $0)
source $SCRIPT_DIR/../init_utils.sh

# Wait for Traefik to be ready (so that we can customize it afterwards)
function wait_for_traefik() {
    FUNCTION_NAME="wait_for_traefik"
    log_info "[$FUNCTION_NAME] Waiting for traefik to be ready..."
    wait_for_k3s_api || return 1

    log_info "[$FUNCTION_NAME] Waiting for traefik helm install job exists..."
    wait_for_resource "sudo kubectl -n kube-system get job helm-install-traefik" || {
        log_fail "[$FUNCTION_NAME] helm-install-traefik job never appeared"
        return 1
    }

    log_info "[$FUNCTION_NAME] Waiting for traefik helm install job complete..."
    sudo kubectl -n kube-system wait --for=condition=complete job/helm-install-traefik --timeout=240s || {
        log_fail "[$FUNCTION_NAME] helm-install-traefik job did not complete"
        sudo kubectl -n kube-system describe job helm-install-traefik || true
        sudo kubectl -n kube-system get events --sort-by=.metadata.creationTimestamp | tail -n 50 || true
        return 1
    }

    log_info "[$FUNCTION_NAME] Waiting for traefik deployment to be present..."
    wait_for_resource "sudo kubectl -n kube-system get deploy traefik" || {
        log_fail "[$FUNCTION_NAME] traefik deployment never appeared"
        return 1
    }

    log_info "[$FUNCTION_NAME] Waiting for traefik deployment to be ready..."
    sudo kubectl -n kube-system rollout status deploy/traefik --timeout=240s || {
        log_fail "[$FUNCTION_NAME] traefik deployment not ready"
        sudo kubectl -n kube-system get pods -o wide | egrep -i 'traefik|helm-install' || true
        return 1
    }

    log_okay "[$FUNCTION_NAME] traefik is ready!"
}

function setup_traefik() {
    # Should be "/var/lib/rancher/k3s/server/manifests"
    MANIFESTS_FOLDER="$1"
    TRAEFIK_TEMPLATE_FILEPATH="$2"

    FUNCTION_NAME="setup_helmchartconfig_traefik"
    log_info "[$FUNCTION_NAME] Writing Traefik HelmChartConfig manifest"

    # Make sure the manifests directory exists
    sudo mkdir -p "$MANIFESTS_FOLDER"

    # Substitute using environment variables using the traefik-config.yaml.tmpl template file
    # Then transfer it to the manifests folder
    export NODEPORT_HTTP NODEPORT_HTTPS
    envsubst '${NODEPORT_HTTP} ${NODEPORT_HTTPS}' \
        < $TRAEFIK_TEMPLATE_FILEPATH \
        | sudo tee $MANIFESTS_FOLDER/traefik-config.yaml >/dev/null
    export -n NODEPORT_HTTP NODEPORT_HTTPS

    if [ $? -eq 0 ]; then
        log_okay "[$FUNCTION_NAME] Traefik HelmChartConfig written to $MANIFESTS_FOLDER/traefik-config.yaml"
    else
        log_warn "[$FUNCTION_NAME] Failed to write Traefik HelmChartConfig"
    fi
}

# Wait for traefik service to be ready (Helps prevent race-conditions from occurring)
wait_for_traefik

# Set up traefik
# FILEPATH_TRAEFIK_CFG_TMPL is provided in simplek3s.env
setup_traefik "$1" "$FILEPATH_TRAEFIK_CFG_TMPL" 
