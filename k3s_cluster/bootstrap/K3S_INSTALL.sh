#!/bin/bash

# Set bash flags 
set -euo pipefail 
# -u            : Error if an unset variable is referenced 
# -e            : Exits on ANY command failure 
# -o pipefail   : Make pipeline fail if any command in them fails 

SCRIPT_DIR=$(dirname $0)
cd $SCRIPT_DIR

# Retrieve all of the needed environment variables from this file
source ./simplek3s.env

COUNT_INDEX="$1"

PARAM_NAME="/simplek3s/$NICKNAME/k3s-token"
REGION="$AWS_REGION"

SWAPFILE_ALLOC_AMT="$SWAPFILE_ALLOC_AMT"

CONTROLLER_HOST="$CONTROLLER_HOST"

NODEPORT_HTTP="$NODEPORT_HTTP"
NODEPORT_HTTPS="$NODEPORT_HTTPS"

LOG_FILE="./K3S_INSTALL.log"
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

### HELPER FUNCTIONS ### 

PLACEHOLDER_TOKEN="__UNINITIALIZED__" # This is the placeholder token that we're supposed to ignore 
wait_for_real_k3s_token() {
  FUNCTION_NAME="wait_for_real_k3s_token"
  local max_attempts="${1:-180}"   # 180 * 2s = 6 minutes
  local sleep_s="${2:-2}"

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
      if [[ -n "$v" && "$v" != "$PLACEHOLDER_TOKEN" ]]; then
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

# Wait for K3s API to be ready
wait_for_k3s_api() {
  FUNCTION_NAME="wait_for_k3s_api"
  log_info "[$FUNCTION_NAME] Waiting for K3s API to be ready..."
  for i in {1..18}; do
    if sudo kubectl get --raw=/readyz >/dev/null 2>&1; then
      log_okay "[$FUNCTION_NAME] K3s API is ready!"
      return 0
    fi
    sleep 10
  done
  log_fail "[$FUNCTION_NAME] K3s API is not ready after 180s"
  return 1
}
# Wait for a kubectl resource to be available
wait_for_resource() {
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
# Wait for kube-system namespace to be ready
wait_for_kubesystem_ready() {
  FUNCTION_NAME="wait_for_kubesystem_ready"
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
}
# Wait for Traefik to be ready (so that we can customize it afterwards)
wait_for_traefik_ready() {
  FUNCTION_NAME="wait_for_traefik_ready"
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

### MAIN SETUP ###
function main_setup() {
  FUNCTION_NAME="main_setup"
  log_info "[$FUNCTION_NAME] Setup for node: $COUNT_INDEX has now STARTED"

  # Main K3S node
  if [ $COUNT_INDEX -eq 0 ]; then
    log_info "[$FUNCTION_NAME] Node equals to 0: Set this node up as PRIMARY node!"
    log_info "[$FUNCTION_NAME] CONTROLLER_HOST $CONTROLLER_HOST"

    log_info "[$FUNCTION_NAME] PRIMARY node is being set up!"
    # Set up first server -  Do NOT use a token (Let K3s automatically generate it)
    curl -sfL https://get.k3s.io | sh -s - server \
      --cluster-init \
      --tls-san="$CONTROLLER_HOST" 2>&1 | tee -a $LOG_FILE

    if [ $? -eq 0 ]; then
      log_okay "[$FUNCTION_NAME] PRIMARY node has been set up!"
    else
      log_fail "[$FUNCTION_NAME] K3s installation command failed on PRIMARY node!"
      exit 1
    fi

    # Read the generated token (server token file)
    log_info "[$FUNCTION_NAME] Store K3s token into AWS SSM Parameter Store..."
    TOKEN="$(sudo cat /var/lib/rancher/k3s/server/token)"

    if [[ -z "$TOKEN" || "$TOKEN" == "$PLACEHOLDER_TOKEN" ]]; then
      log_fail "[$FUNCTION_NAME] token read from disk looks invalid"
      exit 1
    fi

    # Store in Parameter Store (SecureString). Overwrite allows rebuilds.
    aws ssm put-parameter \
      --name "$PARAM_NAME" \
      --type "SecureString" \
      --value "$TOKEN" \
      --overwrite \
      --region "$AWS_REGION"

    if [ $? -eq 0 ]; then
      log_okay "[$FUNCTION_NAME] Stored K3s token into AWS SSM Parameter Store!"
    else
      log_fail "[$FUNCTION_NAME] Something went wrong when storing K3s token into AWS SSM Parameter Store!"
    fi 
  fi

  # Secondary K3S node
  if [ ! $COUNT_INDEX -eq 0 ]; then    
    log_info "[$FUNCTION_NAME] Node doesn't equal 0: Set this node up as SECONDARY node!"
    log_info "[$FUNCTION_NAME] CONTROLLER_HOST: $CONTROLLER_HOST"

    log_info "[$FUNCTION_NAME] Waiting for the PRIMARY node to get set up"
    # Wait until the master node is up
    ETCD_0=down
    while [[ "$ETCD_0" == "down" ]]; do 
      curl --connect-timeout 3 -k https://$CONTROLLER_HOST:6443 && ETCD_0=up || ETCD_0=down
    done
    if [[ "$ETCD_0" == "up" ]]; then
      log_okay "[$FUNCTION_NAME] PRIMARY node is now up! (ETCD_0: $ETCD_0)"
    else
      log_fail "[$FUNCTION_NAME] PRIMARY node is still down! (ETCD_0: $ETCD_0)"
    fi 

    log_info "[$FUNCTION_NAME] Retrieving k3s token!"
    # Try to ping AWS SSM to see if the k3s token is ready
    TOKEN="$(wait_for_real_k3s_token 180 2)"
    log_info "[$FUNCTION_NAME] k3s token retrieved!"

    log_info "[$FUNCTION_NAME] SECONDARY node is being set up!"
    # Set up agent server
    curl -sfL https://get.k3s.io | K3S_TOKEN="$TOKEN" sh -s - server \
      --server "https://$CONTROLLER_HOST:6443" \
      --tls-san="$CONTROLLER_HOST" | tee -a $LOG_FILE 

    if [ $? -eq 0 ]; then
      log_okay "[$FUNCTION_NAME] SECONDARY node has been set up!"
    else
      log_fail "[$FUNCTION_NAME] SECONDARY node has not been set up correctly!"
    fi 

  fi

  log_info "[$FUNCTION_NAME] Setup for node: $COUNT_INDEX has been COMPLETED"
}

### SWAPFILE SETUP ###
function swapfile_setup() {
  FUNCTION_NAME="swapfile_setup"
  log_info "[$FUNCTION_NAME] Set up swapfile has now STARTED"

  log_info "[$FUNCTION_NAME] Allocating $SWAPFILE_ALLOC_AMT to /swapfile"
  sudo fallocate -l "$SWAPFILE_ALLOC_AMT" /swapfile
  
  log_info "[$FUNCTION_NAME] Setting up permissions on /swapfile"
  sudo chmod 0600 /swapfile
  
  log_info "[$FUNCTION_NAME] Make /swapfile into a swapfile"
  sudo mkswap /swapfile
  
  log_info "[$FUNCTION_NAME] Enable swap to use /swapfile"
  sudo swapon /swapfile
  
  log_info "[$FUNCTION_NAME] Backup /etc/fstab"
  sudo cp /etc/fstab /etc/fstab_backup

  log_info "[$FUNCTION_NAME] Log /swapfile into /etc/fstab"
  echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab

  log_info "[$FUNCTION_NAME] Set up swapfile has been COMPLETED"
}

function setup_helmchartconfig_traefik() {
  FUNCTION_NAME="setup_helmchartconfig_traefik"
  log_info "[$FUNCTION_NAME] Writing Traefik HelmChartConfig manifest"
  wait_for_traefik_ready || return 1

  # Make sure the manifests directory exists
  sudo mkdir -p /var/lib/rancher/k3s/server/manifests

  # Substitute using environment variables using the traefik-config.yaml.tmpl template file
  # Then transfer it to the /var/lib/rancher/k3s/server/manifests/ folder
  export NODEPORT_HTTP NODEPORT_HTTPS
  envsubst '${NODEPORT_HTTP} ${NODEPORT_HTTPS}' \
    < ./manifests/traefik-config.yaml.tmpl \
    | sudo tee /var/lib/rancher/k3s/server/manifests/traefik-config.yaml >/dev/null
  export -n NODEPORT_HTTP NODEPORT_HTTPS

  if [ $? -eq 0 ]; then
    log_okay "[$FUNCTION_NAME] Traefik HelmChartConfig written to /var/lib/rancher/k3s/server/manifests/traefik-config.yaml"
  else
    log_warn "[$FUNCTION_NAME] Failed to write Traefik HelmChartConfig"
  fi
}


# Execute the list of actions
swapfile_setup
main_setup
wait_for_kubesystem_ready
setup_helmchartconfig_traefik
