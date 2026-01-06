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

# Determine the controller host
CONTROLLER_HOST="$1"
# Retrieve parameters from SSM Paramstore
K3S_TOKEN_PARAM_NAME="$2"
REGION="$3"
# Determine if the current script is a controller node
IS_CONTROLLER="$4"

init_k3s_controller() {
    CONTROLLER_HOST="$1"
    K3S_TOKEN_PARAM_NAME="$2"
    REGION="$3"

    FUNCTION_NAME="init_k3s_controller"
    log_info "[$FUNCTION_NAME] Setup this node as the K3s CONTROLLER node!"
    log_info "[$FUNCTION_NAME] CONTROLLER_HOST      : $CONTROLLER_HOST"
    log_info "[$FUNCTION_NAME] K3S_TOKEN_PARAM_NAME : $K3S_TOKEN_PARAM_NAME"
    log_info "[$FUNCTION_NAME] REGION               : $REGION"

    # Set up first server -  Do NOT use a token (Let K3s automatically generate it)
    curl -sfL https://get.k3s.io | sh -s - server \
        --cluster-init \
        --tls-san="$CONTROLLER_HOST" 2>&1 | tee -a $LOG_FILE
    if [ $? -eq 0 ]; then
        log_okay "[$FUNCTION_NAME] K3s CONTROLLER node set up!"
    else
        log_fail "[$FUNCTION_NAME] K3s installation command failed on CONTROLLER node!"
        return 1
    fi

    log_info "[$FUNCTION_NAME] Store K3s token into AWS SSM Parameter Store..."
    # Read the generated token (server token file)
    TOKEN="$(sudo cat /var/lib/rancher/k3s/server/token)"
    if ! is_initialized "$TOKEN"; then
        log_fail "[$FUNCTION_NAME] token read from disk looks invalid"
        return 1
    fi
    # Store in Parameter Store (SecureString). Overwrite allows rebuilds.
    aws ssm put-parameter \
        --name "$K3S_TOKEN_PARAM_NAME" \
        --type "SecureString" \
        --value "$TOKEN" \
        --overwrite \
        --region "$REGION"
    if [ $? -eq 0 ]; then
        log_okay "[$FUNCTION_NAME] Stored K3s token into AWS SSM Parameter Store!"
    else
        log_fail "[$FUNCTION_NAME] Something went wrong when storing K3s token into AWS SSM Parameter Store!"
        return 1
    fi

    return 0
}

init_k3s_worker() {
    CONTROLLER_HOST="$1"
    K3S_TOKEN_PARAM_NAME="$2"
    REGION="$3"

    FUNCTION_NAME="init_k3s_worker"
    log_info "[$FUNCTION_NAME] Setup this node as the K3s WORKER node!"
    log_info "[$FUNCTION_NAME] CONTROLLER_HOST      : $CONTROLLER_HOST"
    log_info "[$FUNCTION_NAME] K3S_TOKEN_PARAM_NAME : $K3S_TOKEN_PARAM_NAME"
    log_info "[$FUNCTION_NAME] REGION               : $REGION"

    log_info "[$FUNCTION_NAME] Waiting for the CONTROLLER node to get set up"
    # Wait until the master node is up
    ETCD_0=down
    while [[ "$ETCD_0" == "down" ]]; do 
        curl --connect-timeout 3 -k https://$CONTROLLER_HOST:6443 && ETCD_0=up || ETCD_0=down
    done
    if [[ "$ETCD_0" == "up" ]]; then
        log_okay "[$FUNCTION_NAME] CONTROLLER node is now up! (ETCD_0: $ETCD_0)"
    else
        log_fail "[$FUNCTION_NAME] CONTROLLER node is still down! (ETCD_0: $ETCD_0)"
        return 1
    fi 

    log_info "[$FUNCTION_NAME] Retrieving k3s token!"
    # Try to ping AWS SSM to see if the k3s token is ready
    TOKEN="$(wait_for_valid_ssm_parameter "$K3S_TOKEN_PARAM_NAME" "$REGION" 180 2)" || {
        log_fail "[$FUNCTION_NAME] k3s token failed to be retrieved!"
        return 1
    }
    log_info "[$FUNCTION_NAME] k3s token retrieved!"

    log_info "[$FUNCTION_NAME] WORKER node is being set up!"
    # Set up agent server
    curl -sfL https://get.k3s.io | K3S_TOKEN="$TOKEN" sh -s - server \
        --server "https://$CONTROLLER_HOST:6443" \
        --tls-san="$CONTROLLER_HOST" | tee -a $LOG_FILE 

    if [ $? -eq 0 ]; then
        log_okay "[$FUNCTION_NAME] WORKER node has been set up!"
    else
        log_fail "[$FUNCTION_NAME] WORKER node has not been set up correctly!"
        return 1
    fi


    return 0
}

if [ "$IS_CONTROLLER" = true ]; then
    # If its considered as primary, set up the current node as the controller
    init_k3s_controller "$CONTROLLER_HOST" "$K3S_TOKEN_PARAM_NAME" "$REGION" || {
        log_fail "[$0] init_k3s_controller failed!"
        exit 1
    }
else
    # If its NOT considered as primary, set up the current node as the worker
    init_k3s_worker "$CONTROLLER_HOST" "$K3S_TOKEN_PARAM_NAME" "$REGION" || {
        log_fail "[$0] init_k3s_worker failed"
        exit 1
    }
fi

# Before we proceed with the other scripts: Ensure that its fully set up by making sure that Kubesystem works
wait_for_kubesystem || {
    log_fail "[$0] wait_for_kubesystem failed"
    exit 1
}
