#!/bin/bash

# Set bash flags 
set -euo pipefail 
# -u            : Error if an unset variable is referenced 
# -e            : Exits on ANY command failure 
# -o pipefail   : Make pipeline fail if any command in them fails 

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

function k3s_taint_controlplane() {
    log_info "Tainting Control Plane!"

    # Wait until nodes are visible
    log_info "Check if nodes are all ready"
    wait_for_cmd_1min sudo kubectl wait --for=condition=Ready nodes --all --timeout=10s || {
        log_fail "Nodes are not all ready yet, Aborting"
        return 1
    }
    log_okay "Nodes are all ready"

    log_info "Applying taint onto control-plane (NoSchedule)"
    # Taint all control-plane nodes; ignore "already tainted"
    sudo kubectl taint nodes -l node-role.kubernetes.io/control-plane \
    node-role.kubernetes.io/control-plane=true:NoSchedule --overwrite 2>/dev/null || true
    # Same effect as above, but works with node-role.kubernetes.io/master (works with older configs)
    sudo kubectl taint nodes -l node-role.kubernetes.io/control-plane \
    node-role.kubernetes.io/master=true:NoSchedule --overwrite 2>/dev/null || true
    log_okay "Applied taint onto control-plane (NoSchedule)"

    log_okay "Control Plane Successfully tainted!"
}

log_info "$0: LAUNCHED"

# Perform node type
case "$NODE_TYPE" in
    controller) 
        log_info "Configure K3s: Controller"

        # Wait for everything to be started up
        wait_for_k3s_api || {
            log_fail "Unable to confirm that K3s API is ready"
            exit 1
        }
        wait_for_kubesystem || {
            log_fail "Unable to confirm that Kubesystem is ready"
            exit 1
        }

        # Taint the control plane of K3s
        k3s_taint_controlplane || {
            log_fail "Failed to configure K3s: Taint Control Plane"
            exit 1
        }

        log_okay "Configure K3s: Controller - COMPLETED"
        ;;
    server)
        log_info "Configure K3s Skipped: No configurations needed on server side"
        ;;
    *) 
        log_fail "Configure K3s Failed: Invalid input ($NODE_TYPE)"
        exit 1
        ;;
esac

log_okay "$0: COMPLETED"
