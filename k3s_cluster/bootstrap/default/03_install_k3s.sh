#!/bin/bash

# Set bash flags 
set -euo pipefail 
# -u            : Error if an unset variable is referenced 
# -e            : Exits on ANY command failure 
# -o pipefail   : Make pipeline fail if any command in them fails 

SCRIPT_DIR=$(realpath $(dirname $0))

NODE_TYPE="$2"

# Retrieve all of the needed environment variables from this file
source $SCRIPT_DIR/simplek3s.env
# Retrieve the common functions from common.sh
source $SCRIPT_DIR/common.sh
# Retrieve the common functions from common_aws.sh
source $SCRIPT_DIR/common_aws.sh

function upload_k3s_token() {
    local token="${1}"
    local ssmkey_k3s_token="k3s-token"
    local token_type="SecureString"
    set_ssm_param_overwrite "$ssmkey_k3s_token" "$token_type" "$token" || return 1
    return 0
}

function download_k3s_token() {
    local ssmkey_k3s_token="k3s-token"
    local decrypt="decrypt"
    local token="$(wait_ssm_param "$ssmkey_k3s_token" "$decrypt")" || return 1
    echo "$token"
    return 0
}

function k3s_controller() {
    log_info "Installing Controller!"
    log_info "CONTROLLER_HOST $CONTROLLER_HOST"

    # Set up controller node - Do NOT use a token (Let K3s automatically generate it)
    log_info "Install K3s controller"
    install_k3s_controller || return 1
    log_okay "Controller successfully installed!"

    # Read the generated token (server token file)
    log_info "Getting K3s token to store into AWS SSM Parameter Store"
    local token=$(get_k3s_token) || return 1
    log_okay "Succeeded to get K3s token!"

    # Store in Parameter Store (SecureString). Overwrite allows rebuilds.
    log_info "Upload K3s token into AWS SSM Parameter Store"
    upload_k3s_token "$token" || return 1
    log_okay "Succeeded to upload the token to AWS Parameter Store"
}

function k3s_server() {
    log_info "Installing Server!"
    log_info "CONTROLLER_HOST $CONTROLLER_HOST"

    # Wait until the master node is up
    log_info "Checking if the controller is up"
    is_controller_okay || return 1
    log_okay "Controller node is confirmed to be up!"

    # Try to ping AWS SSM to see if the k3s token is ready
    log_info "Retrieving K3s token!"
    local token="$(download_k3s_token)" || return 1
    log_okay "K3s token has been retrieved!"

    # Set up K3s server
    log_info "Set up K3s Server"
    install_k3s_server "$token" || return 1
    log_okay "K3s Server successfully installed!"
}

log_info "$0: LAUNCHED"
# Perform node type
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
    *) 
        log_fail "Install K3s Failed: Invalid input ($NODE_TYPE)"
        exit 1
        ;;
esac
log_okay "$0: COMPLETED"


