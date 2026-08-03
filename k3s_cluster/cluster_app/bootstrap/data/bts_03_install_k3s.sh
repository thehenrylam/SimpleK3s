#!/bin/bash

# Set bash flags
set -euo pipefail
# -u            : Error if an unset variable is referenced
# -e            : Exits on ANY command failure
# -o pipefail   : Make pipeline fail if any command in them fails

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# NODE_TYPE : "controller" | "server" | "agent"
# FLAG      : optional second argument (controller only)
#   --recreate           Join the existing cluster as a server, skipping detection
#   --force-cluster-init Destroy and reinitialize the cluster from scratch (DATA LOSS)
#
# With no flag, "controller" decides between those two by probing for an existing
# cluster rather than assuming node-0 means "found a new one" — see print_help.
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
  controller           Node-0. Initializes the cluster, or joins an existing one
                       (see Controller behaviour below)
  server               Join the cluster as a control-plane server
  agent                Join the cluster as an agent

Flags (controller only):
  --recreate           Join the existing cluster as a normal server, skipping
                       detection. Use when you know the cluster is still running.
  --force-cluster-init Destroy and reinitialize the cluster from scratch.
                       ALL workloads and etcd state will be permanently lost.
  --help               Show this message

Controller behaviour (no flag):
  Node-0-ness does not imply a cluster needs founding — a replaced node-0 boots
  with a blank disk and is indistinguishable from a first boot. So the choice is
  made from two probes instead: whether Parameter Store holds a real join token,
  and whether a control plane answers on 6443.

    token   server   action
    -----   ------   ------------------------------------------------
    no      no       Nothing exists yet; initialize a new cluster
    yes     yes      Cluster is live; join it as a server
    yes     no       Ambiguous; stop and ask for an explicit flag
    no      yes      Ambiguous; stop and ask for an explicit flag

  The ambiguous cases refuse rather than guess: founding a cluster on top of a
  live one overwrites its join token and splits it in two.

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

# One-shot check: does Parameter Store hold a REAL token?
#
# Terraform creates the parameter up front seeded with "__UNINITIALIZED__", so mere
# existence proves nothing — get_ssm already treats both empty and that placeholder as
# failure, which makes a plain call the entire test.
#
# Deliberately not download_k3s_token: that wraps wait_ssm and would block for minutes
# waiting on a token that, on a genuinely fresh deploy, is legitimately absent.
function k3s_token_exists() {
    local ssmkey_k3s_token="k3s-token"
    local decrypt="decrypt"
    get_ssm "$ssmkey_k3s_token" "$decrypt" >/dev/null 2>&1
}

# Join a cluster that already exists, as a normal control-plane server.
# The token is already in Parameter Store from the original init — never overwrite it.
function join_existing_cluster() {
    log_info "Registering node-0 as a normal server"

    log_info "Checking if the controller is up"
    is_controller_okay || return 1
    log_okay "Controller node is confirmed to be up!"

    log_info "Retrieving K3s token from SSM"
    local token
    token="$(download_k3s_token)" || return 1
    log_okay "K3s token retrieved!"

    log_info "Installing K3s as server"
    install_k3s_server "$token" || return 1
    log_okay "Node-0 successfully registered as server!"
}

# Found a brand new cluster and publish its token.
# Destructive if a cluster already exists: the put overwrites the live join token.
function init_new_cluster() {
    log_info "Installing K3s controller (cluster-init)"
    install_k3s_controller || return 1
    log_okay "Controller successfully installed!"

    log_info "Getting K3s token to store into AWS SSM Parameter Store"
    local token
    token="$(get_k3s_token)" || return 1
    log_okay "Succeeded to get K3s token!"

    log_info "Upload K3s token into AWS SSM Parameter Store"
    upload_k3s_token "$token" || return 1
    log_okay "Succeeded to upload the token to AWS Parameter Store"
}

# Pick between founding a cluster and joining one, from evidence rather than from the
# node's index. Node-0-ness says nothing about whether a cluster already exists: a
# replaced node-0 boots with a blank disk and looks identical to a first boot.
function autodetect_and_install() {
    local has_token="false"
    local has_server="false"

    if k3s_token_exists; then has_token="true"; fi
    if is_controller_alive; then has_server="true"; fi

    log_info "Cluster detection: token_in_pstore=${has_token} server_on_6443=${has_server}"

    if [[ "$has_token" == "false" && "$has_server" == "false" ]]; then
        log_info "No existing cluster found — initializing a new one."
        init_new_cluster || return 1
        return 0
    fi

    if [[ "$has_token" == "true" && "$has_server" == "true" ]]; then
        log_info "An existing cluster is live — joining it instead of re-initializing."
        join_existing_cluster || return 1
        return 0
    fi

    # Exactly one signal present. This is where a wrong guess costs data: founding a
    # cluster here can overwrite a live join token, and joining one can hang forever.
    # Stop and make a human decide.
    log_fail "Ambiguous cluster state — refusing to guess."
    log_fail "  token in Parameter Store : ${has_token}"
    log_fail "  server answering on 6443 : ${has_server}"
    log_fail "Re-run with an explicit choice:"
    log_fail "  --recreate            join the existing cluster as a server"
    log_fail "  --force-cluster-init  discard any existing cluster and start fresh (DATA LOSS)"
    return 1
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

    case "$FLAG" in
        --recreate)
            # Operator override: join the existing cluster, no questions asked.
            log_info "Joining the existing cluster as a server (--recreate)"
            join_existing_cluster || return 1
            ;;
        --force-cluster-init)
            # Operator override: found a new cluster regardless of what already exists.
            log_info "Initializing a new cluster (--force-cluster-init)"
            init_new_cluster || return 1
            ;;
        "")
            # Default: work out which of the two above is correct.
            autodetect_and_install || return 1
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
