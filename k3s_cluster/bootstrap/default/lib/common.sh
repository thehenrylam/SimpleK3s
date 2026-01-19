#!/bin/bash

# COMMON UTILITIES
# - Used to abstract away the complexities of how logs are handled
# - Used to abstract K3s operations (installation, token fetching, etc)

LIBRARY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$LIBRARY_DIR/../"
# Retrieve all of the needed environment variables from this file
source "$SCRIPT_DIR/simplek3s.env"

# Get date
function print_date() {
    echo "$(date +'%Y-%m-%dT%H:%M:%S.%3N')"
}

# Logging functions
function log_info() {
    printf '%s [INFO] [%s] %s\n' "$(print_date)" "${FUNCNAME[1]}" "$1"
}

function log_okay() {
    printf '%s [OKAY] [%s] %s\n' "$(print_date)" "${FUNCNAME[1]}" "$1"
}

function log_warn() {
    printf '%s [WARN] [%s] %s\n' "$(print_date)" "${FUNCNAME[1]}" "$1"
}

function log_fail() {
    printf '%s [FAIL] [%s] %s\n' "$(print_date)" "${FUNCNAME[1]}" "$1"
}

# Install K3s (Controller)
function install_k3s_controller() {
    # simplek3s.env variables:
    # - K3S_INSTALL_URL
    # - CONTROLLER_HOST

    local controller_host="${1:-$CONTROLLER_HOST}"

    curl -sfL "$K3S_INSTALL_URL" | sh -s - server \
        --cluster-init \
        --tls-san="$controller_host" 2>&1
}
# Install K3s (Server)
function install_k3s_server() {
    # simplek3s.env variables:
    # - K3S_INSTALL_URL
    # - CONTROLLER_HOST

    local token="${1}"
    local controller_host="${2:-$CONTROLLER_HOST}"

    curl -sfL "$K3S_INSTALL_URL" | K3S_TOKEN="$token" sh -s - server \
        --server "https://$controller_host:6443" \
        --tls-san="$controller_host" 2>&1 
}

# Get the K3s token
function get_k3s_token() {
    # Define an uninitialized value to set up a fallback output 
    local PLACEHOLDER_TOKEN="__UNINITIALIZED__"
    local output_token="$(sudo cat /var/lib/rancher/k3s/server/token)"
    if [[ -z "$output_token" || "$output_token" == "$PLACEHOLDER_TOKEN" ]]; then
        echo "$output_token"
        return 1
    else
        echo "$output_token"
        return 0
    fi
    return 0
}

# Waiting functions
function wait_for_cmd_1min() {
    wait_for_cmd 6 10 "$@"
}

function wait_for_cmd_3min() {
    wait_for_cmd 18 10 "$@"
}

function wait_for_cmd_5min() {
    wait_for_cmd 30 10 "$@"
}

function wait_for_cmd() {
    local max_attempts="$1"
    local sleep_s="$2"
    shift 2 # Ignore the first 2 arguments for the upcoming $@ command
    for ((i=1; i<=max_attempts; i++)); do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        log_info "Waiting... ($i/$max_attempts)"
        sleep "$sleep_s"
    done
    return 1
}

# Wait for the controller to be ready
function is_controller_okay() {
    local controller_host="${1:-$CONTROLLER_HOST}"
    log_info "Waiting for the controller to be reachable"

    wait_for_cmd_3min curl --connect-timeout 3 -k \
        "https://$controller_host:6443/readyz" || {
        log_fail "The controller node cannot be reached in time!"
        return 1
    }

    log_okay "The controller node is reachable!"
}

# Wait for K3s API to be ready
function wait_for_k3s_api() {
    log_info "Waiting for K3s API to be reachable"

    wait_for_cmd_3min sudo kubectl get --raw=/readyz || {
        log_fail "The K3s API cannot be reached in time!"
        return 1
    }

    log_okay "The K3s API is reachable!"
}

# Wait for kube-system namespace to be ready
function wait_for_kubesystem() {
    log_info "Waiting for kube-system to be ready..."

    log_info "Waiting for kube-system namespace"
    wait_for_cmd_3min sudo kubectl get ns kube-system || {
        log_fail "kube-system namespace missing"
        return 1
    }

    log_info "Waiting for kube-system/kube-root-ca.crt configmap"
    wait_for_cmd_3min sudo kubectl -n kube-system get cm kube-root-ca.crt || {
        log_fail "kube-root-ca.crt missing in kube-system"
        return 1
    }

    log_okay "kube-system is ready!"
}


