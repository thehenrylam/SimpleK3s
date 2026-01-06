#!/bin/bash

function print_date() {
    echo "$(date +'%Y-%m-%dT%H:%M:%S.%3N')"
}
function log_info() {
    echo -e "$(print_date) [INFO] $1" 2>&1 | tee -a $LOG_FILE
}
function log_okay() {
    echo -e "$(print_date) [OKAY] $1" 2>&1 | tee -a $LOG_FILE
}
function log_warn() {
    echo -e "$(print_date) [WARN] $1" 2>&1 | tee -a $LOG_FILE
}
function log_fail() {
    echo -e "$(print_date) [FAIL] $1" 2>&1 | tee -a $LOG_FILE
}

# Determine if the current value is initialized or not
function is_initialized() {
    UNINITIALIZED_VALUE="__UNINITIALIZED__"
    if [[ -z "$1" || "$1" == "$UNINITIALIZED_VALUE" ]]; then
        return 1 # It is UNINITIALIZED
    else
        return 0 # It is INITIALIZED
    fi
}

# Wait for a valid SSM parameter
function wait_for_valid_ssm_parameter() {
    PARAM_NAME="$1"
    REGION="$2"

    FUNCTION_NAME="wait_for_valid_ssm_parameter"
    local max_attempts="${3:-180}"   # 180 * 2s = 6 minutes
    local sleep_s="${4:-2}"

    for ((i=1; i<=max_attempts; i++)); do
        # get value (may fail temporarily)
        local v=""
        if v="$(aws ssm get-parameter \
            --name "$PARAM_NAME" \
            --with-decryption \
            --query "Parameter.Value" \
            --output text \
            --region "$REGION" 2>/dev/null)"; then

            # "ready" when it's not empty and not the placeholder
            if is_initialized "$v"; then
                echo "$v"
                return 0
            fi
        fi

        log_info "[$FUNCTION_NAME] Waiting for real token in SSM (attempt ${i}/${max_attempts})..."
        sleep "$sleep_s"
    done

    log_fail "[$FUNCTION_NAME] Timed out waiting for k3s token to be populated in SSM."
    return 1
}

# Wait for a resource to be available
function wait_for_resource() {
    FUNCTION_NAME="wait_for_resource"
    log_info "[$FUNCTION_NAME] Waiting for resource to be available..."
    # usage: wait_for_resource <kubectl args that must succeed>
    for i in {1..18}; do
        if eval "$@" >/dev/null 2>&1; then
            log_okay "[$FUNCTION_NAME] Resource is available!"
            return 0
        fi
        sleep 10
    done
    log_fail "[$FUNCTION_NAME] Resource is not available after 180s"
    return 1
}

# Wait for K3s API to be ready
function wait_for_k3s_api() {
    FUNCTION_NAME="wait_for_k3s_api"
    log_info "[$FUNCTION_NAME] Waiting for K3s API to be ready"
    wait_for_resource "sudo kubectl get --raw=/readyz" || {
        log_fail "[$FUNCTION_NAME] Waiting for K3s API timed out"
        return 1
    }
    log_okay "[$FUNCTION_NAME] K3s API is now ready!"
    return 0
}

# Wait for kube-system namespace to be ready
function wait_for_kubesystem() {
  FUNCTION_NAME="wait_for_kubesystem"
  log_info "[$FUNCTION_NAME] Waiting for kube-system to be ready..."
  wait_for_k3s_api || return 1

  log_info "[$FUNCTION_NAME] Waiting for kube-system namespace..."
  wait_for_resource "sudo kubectl get ns kube-system" || {
    log_fail "[$FUNCTION_NAME] kube-system namespace missing"
    return 1
  }

  log_info "[$FUNCTION_NAME] Waiting for kube-system/kube-root-ca.crt configmap..."
  wait_for_resource "sudo kubectl -n kube-system get cm kube-root-ca.crt" || {
    log_fail "[$FUNCTION_NAME] kube-root-ca.crt missing in kube-system"
    return 1
  }

  log_okay "[$FUNCTION_NAME] kube-system is ready!"
  return 0
}
