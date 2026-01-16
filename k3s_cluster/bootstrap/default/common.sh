#!/bin/bash

# COMMON UTILITIES
# - Used to abstract away the complexities of how logs are handled
# - Used to abstract K3s operations (installation, token fetching, etc)

# Set bash flags 
set -euo pipefail 
# -u            : Error if an unset variable is referenced 
# -e            : Exits on ANY command failure 
# -o pipefail   : Make pipeline fail if any command in them fails 

SCRIPT_DIR=$(realpath $(dirname $0))
# Retrieve all of the needed environment variables from this file
source $SCRIPT_DIR/simplek3s.env

LOG_FILE="$1"

# Get date
function print_date() {
    echo "$(date +'%Y-%m-%dT%H:%M:%S.%3N')"
}

# Logging functions
function log_info() {
    local _fcnname="${FUNCNAME[1]}"
    echo -e "$(print_date) [INFO] [$_fcnname] $1" 2>&1 | tee -a $LOG_FILE
}

function log_okay() {
    local _fcnname="${FUNCNAME[1]}"
    echo -e "$(print_date) [OKAY] [$_fcnname] $1" 2>&1 | tee -a $LOG_FILE
}

function log_warn() {
    local _fcnname="${FUNCNAME[1]}"
    echo -e "$(print_date) [WARN] [$_fcnname] $1" 2>&1 | tee -a $LOG_FILE
}

function log_fail() {
    local _fcnname="${FUNCNAME[1]}"
    echo -e "$(print_date) [FAIL] [$_fcnname] $1" 2>&1 | tee -a $LOG_FILE
}

# Install K3s (Controller)
function install_k3s_controller() {
    # simplek3s.env variables:
    # - K3S_INSTALL_URL
    # - CONTROLLER_HOST

    local controller_host="${1:-$CONTROLLER_HOST}"

    curl -sfL "$K3S_INSTALL_URL" | sh -s - server \
        --cluster-init \
        --tls-san="$controller_host" 2>&1 | tee -a $LOG_FILE
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
        --tls-san="$controller_host" 2>&1 | tee -a $LOG_FILE 
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

function is_controller_okay() {
    local controller_host="${1:-$CONTROLLER_HOST}"

    local ETCD_0="down"
    while [[ "$ETCD_0" == "down" ]]; do 
        curl --connect-timeout 3 -k https://$controller_host:6443 && ETCD_0=up || ETCD_0=down
    done
    if [[ "$ETCD_0" == "up" ]]; then
        return 0
    else
        return 1
    fi
}

# Wait for a kubectl resource to be available (for 3 minutes)
function wait_for_resource() {
    # usage: wait_for_resource <kubectl args that must succeed>
    local max_attempts=18
    local sleep_s=10
    for ((i=1; i<=max_attempts; i++)); do
        if eval "$@" >/dev/null 2>&1; then
            log_okay "Available!"
            return 0
        fi
        log_info "Waiting... ($i/$max_attempts)"
        sleep "$sleep_s"
    done
    log_fail "Resource not available after $(( $max_attempts*$sleep_s ))s"
    return 1
}

# Wait for K3s API to be ready
function wait_for_k3s_api() {
    log_info "Waiting for K3s API to be ready..."
    
    wait_for_resource "sudo kubectl get --raw=/readyz" || {
        log_fail "K3s API couldn't be reached!"
        return 1
    }

    log_okay "K3s API is now ready!"
}

# Wait for kube-system namespace to be ready
function wait_for_kubesystem_ready() {
    log_info "Waiting for kube-system to be ready..."
    wait_for_k3s_api || return 1

    log_info "Waiting for kube-system namespace..."
    wait_for_resource "sudo kubectl get ns kube-system" || {
        log_fail "kube-system namespace missing"
        return 1
    }

    log_info "Waiting for kube-system/kube-root-ca.crt configmap..."
    wait_for_resource "sudo kubectl -n kube-system get cm kube-root-ca.crt" || {
        log_fail "kube-root-ca.crt missing in kube-system"
        return 1
    }

    log_okay "kube-system is ready!"
}


