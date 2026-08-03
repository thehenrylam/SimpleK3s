#!/bin/bash

# COMMON UTILITIES
# - Used to abstract away the complexities of how logs are handled
# - Used to abstract K3s operations (installation, token fetching, etc)

LIBRARY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$LIBRARY_DIR/../"
# Retrieve all of the needed environment variables from this file
# shellcheck disable=SC1091
source "$SCRIPT_DIR/simplek3s.env"

# Get date
function print_date() {
    date +'%Y-%m-%dT%H:%M:%S.%3N'
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

    curl -sfL "$K3S_INSTALL_URL" | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server \
        --cluster-init \
        --disable=traefik \
        --tls-san="$controller_host" 2>&1
}
# Install K3s (Server)
function install_k3s_server() {
    # simplek3s.env variables:
    # - K3S_INSTALL_URL
    # - CONTROLLER_HOST

    local token="${1}"
    # Two different things, deliberately separate arguments:
    #   join_host — the peer we contact to join. Outbound, someone else's address.
    #               Overridden during a node-0 repair, where the default is us.
    #   tls_san   — an extra name OUR serving certificate must be valid for.
    #               Inbound, and it stays the cluster's advertised address no
    #               matter which peer we happened to join through.
    #
    # They were one variable, which set --tls-san to whichever node we joined via
    # — advertising an address this node does not own. Harmless while k3s also
    # auto-adds the node's own IP, but they must be separate before CONTROLLER_HOST
    # becomes a load balancer, where every node needs the LB as a SAN while the
    # join target may be the LB or a specific peer.
    local join_host="${2:-$CONTROLLER_HOST}"
    local tls_san="${3:-$CONTROLLER_HOST}"

    curl -sfL "$K3S_INSTALL_URL" | INSTALL_K3S_VERSION="$K3S_VERSION" K3S_TOKEN="$token" sh -s - server \
        --server "https://$join_host:6443" \
        --disable=traefik \
        --tls-san="$tls_san" 2>&1
}

# Install K3s (Agent)
function install_k3s_agent() {
    # simplek3s.env variables:
    # - K3S_INSTALL_URL
    # - CONTROLLER_HOST

    local token="${1}"
    local controller_host="${2:-$CONTROLLER_HOST}"
    local provider_id="${3:-}"

    local extra_args=()
    [[ -n "$provider_id" ]] && extra_args+=(--kubelet-arg="provider-id=$provider_id")

    curl -sfL "$K3S_INSTALL_URL" | INSTALL_K3S_VERSION="$K3S_VERSION" K3S_TOKEN="$token" sh -s - agent \
        --server "https://$controller_host:6443" \
        "${extra_args[@]}" 2>&1
}

# Get the K3s token
function get_k3s_token() {
    # Define an uninitialized value to set up a fallback output 
    local PLACEHOLDER_TOKEN="__UNINITIALIZED__"
    local output_token
    output_token="$(sudo cat /var/lib/rancher/k3s/server/token)"
    if [[ -z "$output_token" || "$output_token" == "$PLACEHOLDER_TOKEN" ]]; then
        echo "$output_token"
        return 1
    else
        echo "$output_token"
        return 0
    fi
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

# Format a block device as ext4 with a filesystem label, ONLY if no filesystem
# exists yet (idempotent — preserves data when a volume is re-attached).
# NOTE: ext4 labels max out at 16 chars; keep them short.
function ensure_fs_ext4() {
    local device="$1"
    local fs_label="$2"

    local fs_type
    fs_type="$(sudo blkid -o value -s TYPE "$device" 2>/dev/null || true)"

    if [[ -z "$fs_type" ]]; then
        log_info "No filesystem found on $device; formatting as ext4 (label '$fs_label')..."
        sudo mkfs.ext4 -L "$fs_label" "$device" || return 1
        log_okay "Formatted $device as ext4 with label '$fs_label'."
    else
        log_info "Filesystem '$fs_type' already exists on $device; skipping format."
    fi
}

# Mount a labeled ext4 filesystem at a path, persisted via /etc/fstab
# (idempotent — safe to re-run; nofail keeps boot resilient if the disk is gone)
function ensure_labeled_mount() {
    local fs_label="$1"
    local mount_path="$2"

    local fstab_filepath="/etc/fstab"
    local fstab_label="LABEL=${fs_label}"

    sudo mkdir -p "$mount_path" || return 1

    if ! grep -q "$fstab_label" "$fstab_filepath"; then
        echo "$fstab_label $mount_path ext4 defaults,nofail 0 2" | sudo tee -a "$fstab_filepath" >/dev/null || return 1
        log_info "Added '$fstab_label' to $fstab_filepath."
    fi

    if ! mountpoint -q "$mount_path"; then
        sudo mount -a || return 1
        log_okay "Mounted $mount_path."
    else
        log_info "$mount_path already mounted."
    fi
}

# One-shot probe: is a control plane answering on 6443 RIGHT NOW?
#
# Deliberately not is_controller_okay, which waits up to 3 minutes for a controller to
# come up. That is the right question when joining a cluster you know exists; it is the
# wrong one when asking "does a cluster exist at all?", where a 3-minute stall on the
# expected answer of "no" would delay every fresh deploy.
#
# Any HTTP response counts as evidence a cluster is there — hence no `-f`. A control
# plane that is up but reporting not-ready still means a cluster exists, and treating
# that as "nothing here" is exactly the mistake that splits a cluster in two.
function is_controller_alive() {
    local controller_host="${1:-$CONTROLLER_HOST}"
    local timeout_s="${2:-3}"

    curl -sk -o /dev/null \
        --connect-timeout "$timeout_s" \
        --max-time "$((timeout_s * 2))" \
        "https://$controller_host:6443/readyz"
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


