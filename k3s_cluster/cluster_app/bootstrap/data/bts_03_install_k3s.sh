#!/bin/bash

# Set bash flags
set -euo pipefail
# -u            : Error if an unset variable is referenced
# -e            : Exits on ANY command failure
# -o pipefail   : Make pipeline fail if any command in them fails

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# NODE_TYPE : "controller" | "server" | "agent"
# FLAG      : optional second argument (controller only)
#   --recreate           Re-register node-0 as a normal server (day-2 node replacement)
#   --force-cluster-init Destroy and reinitialize the cluster from scratch (DATA LOSS)
NODE_TYPE="${1:-}"
FLAG="${2:-}"

# Retrieve the common functions from common.sh (Calls upon simplek3s.env file)
# shellcheck source=k3s_cluster/cluster_app/bootstrap/data/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# Retrieve the AWS specific functions from aws.sh
# shellcheck source=k3s_cluster/cluster_app/bootstrap/data/lib/providers/aws.sh
source "$SCRIPT_DIR/lib/providers/aws.sh"

function print_help() {
    cat <<EOF
Usage: $(basename "$0") <NODE_TYPE> [FLAG]

NODE_TYPE:
  controller           Initialize the cluster (node-0, first boot)
  server               Join the cluster as a control-plane server
  agent                Join the cluster as an agent

Flags (controller only):
  --recreate           Re-register node-0 as a normal server. Use when node-0
                       has been replaced and the existing cluster is still running.
  --force-cluster-init Destroy and reinitialize the cluster from scratch.
                       ALL workloads and etcd state will be permanently lost.
  --help               Show this message

Idempotency:
  If K3s is already running the script exits cleanly with no changes.
  Pass --recreate or --force-cluster-init (controller only) to override.
EOF
}

# --help is accepted in either argument position
if [[ "$NODE_TYPE" == "--help" || "$FLAG" == "--help" ]]; then
    print_help
    exit 0
fi

if [[ -z "$NODE_TYPE" ]]; then
    echo "Error: NODE_TYPE is required." >&2
    echo "" >&2
    print_help >&2
    exit 2
fi

if [[ -n "$FLAG" && "$FLAG" != "--recreate" && "$FLAG" != "--force-cluster-init" ]]; then
    echo "Error: Unknown flag: '$FLAG'" >&2
    echo "" >&2
    print_help >&2
    exit 2
fi

if [[ -n "$FLAG" && "$NODE_TYPE" != "controller" ]]; then
    echo "Error: $FLAG is only valid for NODE_TYPE=controller (got: '$NODE_TYPE')" >&2
    echo "" >&2
    print_help >&2
    exit 2
fi

function upload_k3s_token() {
    local token="${1}"
    local ssmkey_k3s_token="k3s-token"
    local token_type="SecureString"
    ssm_put "$ssmkey_k3s_token" "$token_type" "$token" "true" || return 1
    return 0
}

function download_k3s_token() {
    local ssmkey_k3s_token="k3s-token"
    local decrypt="decrypt"
    local token
    token="$(wait_ssm "$ssmkey_k3s_token" "$decrypt")" || return 1
    echo "$token"
    return 0
}

function k3s_controller() {
    log_info "NODE_TYPE=controller  FLAG=${FLAG:-<none>}  CONTROLLER_HOST=$CONTROLLER_HOST"

    # Idempotency: if K3s is already running, behaviour depends on the flag.
    if systemctl is-active --quiet k3s 2>/dev/null; then
        case "$FLAG" in
            "")
                log_info "K3s controller is already running — skipping."
                log_info "Pass --recreate to re-register as a server, or --force-cluster-init to reinitialize the cluster."
                return 0
                ;;
            --recreate)
                log_info "K3s is already running and the node is joined — --recreate has no effect."
                return 0
                ;;
            --force-cluster-init)
                log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                log_warn "!! WARNING: --force-cluster-init is set               !!"
                log_warn "!! The running cluster will be DESTROYED and          !!"
                log_warn "!! reinitialized. ALL data, workloads, and etcd       !!"
                log_warn "!! state will be permanently lost.                    !!"
                log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                ;;
        esac
    fi

    local token
    case "$FLAG" in
        --recreate)
            # Node-0 replacement: rejoin the existing cluster as a normal server.
            # The cluster token already exists in SSM from the original init.
            log_info "Re-registering node-0 as a normal server (--recreate)"

            log_info "Checking if the controller is up"
            is_controller_okay || return 1
            log_okay "Controller node is confirmed to be up!"

            log_info "Retrieving K3s token from SSM"
            token="$(download_k3s_token)" || return 1
            log_okay "K3s token retrieved!"

            log_info "Installing K3s as server"
            install_k3s_server "$token" || return 1
            log_okay "Node-0 successfully re-registered as server!"
            ;;
        "" | --force-cluster-init)
            # First boot or forced re-init: create a new cluster.
            log_info "Installing K3s controller (cluster-init)"
            install_k3s_controller || return 1
            log_okay "Controller successfully installed!"

            log_info "Getting K3s token to store into AWS SSM Parameter Store"
            token="$(get_k3s_token)" || return 1
            log_okay "Succeeded to get K3s token!"

            log_info "Upload K3s token into AWS SSM Parameter Store"
            upload_k3s_token "$token" || return 1
            log_okay "Succeeded to upload the token to AWS Parameter Store"
            ;;
    esac
}

function k3s_server() {
    log_info "NODE_TYPE=server  CONTROLLER_HOST=$CONTROLLER_HOST"

    if systemctl is-active --quiet k3s 2>/dev/null; then
        log_info "K3s server is already running — skipping install."
        return 0
    fi

    log_info "Checking if the controller is up"
    is_controller_okay || return 1
    log_okay "Controller node is confirmed to be up!"

    log_info "Retrieving K3s token!"
    local token
    token="$(download_k3s_token)" || return 1
    log_okay "K3s token has been retrieved!"

    log_info "Set up K3s Server"
    install_k3s_server "$token" || return 1
    log_okay "K3s Server successfully installed!"
}

function k3s_agent() {
    log_info "NODE_TYPE=agent  CONTROLLER_HOST=$CONTROLLER_HOST"

    if systemctl is-active --quiet k3s-agent 2>/dev/null; then
        log_info "K3s agent is already running — skipping install."
        return 0
    fi

    log_info "Checking if the controller is up"
    is_controller_okay || return 1
    log_okay "Controller node is confirmed to be up!"

    log_info "Retrieving K3s token!"
    local token
    token="$(download_k3s_token)" || return 1
    log_okay "K3s token has been retrieved!"

    log_info "Fetching EC2 provider ID"
    local provider_id
    provider_id="$(get_ec2_provider_id)" || return 1
    log_info "Provider ID: $provider_id"

    log_info "Set up K3s Agent"
    install_k3s_agent "$token" "$CONTROLLER_HOST" "$provider_id" || return 1
    log_okay "K3s Agent successfully installed!"
}

log_info "$0: LAUNCHED"
case "$NODE_TYPE" in
    controller)
        log_info "Install K3s: Controller"
        k3s_controller || {
            log_fail "Failed to set up K3s: Controller"
            exit 1
        }
        log_okay "Install K3s: Controller - COMPLETED"
        ;;
    server)
        log_info "Install K3s: Server"
        k3s_server || {
            log_fail "Failed to set up K3s: Server"
            exit 1
        }
        log_okay "Install K3s: Server - COMPLETED"
        ;;
    agent)
        log_info "Install K3s: Agent"
        k3s_agent || {
            log_fail "Failed to set up K3s: Agent"
            exit 1
        }
        log_okay "Install K3s: Agent - COMPLETED"
        ;;
    *)
        echo "Error: Unknown NODE_TYPE: '$NODE_TYPE'" >&2
        echo "" >&2
        print_help >&2
        exit 2
        ;;
esac
log_okay "$0: COMPLETED"
