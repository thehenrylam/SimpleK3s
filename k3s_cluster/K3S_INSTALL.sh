#!/bin/bash

SECRET="K_THIS_IS_A_TOKEN"
CONTROLLER_HOST="10.0.1.100"

SWAPFILE_ALLOC_AMOUNT="2G"

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

### MAIN SETUP ###
function main_setup() {
  log_info "Setup for node: ${count_index} has now STARTED"

  # Main K3S node
  if [ ${count_index} -eq 0 ]; then
    log_info "Node equals to 0: Set this node up as PRIMARY node!"
    log_info "K3S_TOKEN: $SECRET"
    log_info "CONTROLLER_HOST $CONTROLLER_HOST"

    log_info "PRIMARY node is being set up!"
    # Set up first server
    curl -sfL https://get.k3s.io | K3S_TOKEN="$SECRET" sh -s - server \
      --cluster-init \
      --tls-san="$CONTROLLER_HOST" 2>&1 | tee -a $LOG_FILE # Optional, needed if using a fixed registration address

    if [ $? -eq 0 ]; then
      log_okay "PRIMARY node has been set up!"
      # Set up HelmChartConfigs
      setup_helmchartconfig_traefik
    else
      log_fail "PRIMARY node has not been set up correctly!"
    fi 

  fi

  # Secondary K3S node
  if [ ! ${count_index} -eq 0 ]; then
    log_info "Node doesn't equal 0: Set this node up as SECONDARY node!"
    log_info "K3S_TOKEN: $K3S_TOKEN"
    log_info "CONTROLLER_HOST: $CONTROLLER_HOST"

    log_info "Waiting for the PRIMARY node to get set up"
    # Wait until the master node is up
    ETCD_0=down
    while [[ "$ETCD_0" == "down" ]]; do 
      curl --connect-timeout 3 -k https://$CONTROLLER_HOST:6443 && ETCD_0=up || ETCD_0=down
    done
    if [[ "$ETCD_0" == "up" ]]; then
      log_okay "PRIMARY node is now up! (ETCD_0: $ETCD_0)"
    else
      log_fail "PRIMARY node is still down! (ETCD_0: $ETCD_0)"
    fi 

    log_info "SECONDARY node is being set up!"
    # Set up agent server
    curl -sfL https://get.k3s.io | K3S_TOKEN=$SECRET sh -s - server \
      --server https://$CONTROLLER_HOST:6443 \
      --tls-san=$CONTROLLER_HOST 2>&1 | tee -a $LOG_FILE # Optional, needed if using a fixed registration address
    
    if [ $? -eq 0 ]; then
      log_okay "SECONDARY node has been set up!"
    else
      log_fail "SECONDARY node has not been set up correctly!"
    fi 

  fi

  log_info "Setup for node: ${count_index} has been COMPLETED"
}

### SWAPFILE SETUP ###
function swapfile_setup() {
  log_info "Set up swapfile has now STARTED"

  log_info "Allocating $SWAPFILE_ALLOC_AMOUNT to /swapfile"
  sudo fallocate -l "$SWAPFILE_ALLOC_AMOUNT" /swapfile
  
  log_info "Setting up permissions on /swapfile"
  sudo chmod 0600 /swapfile
  
  log_info "Make /swapfile into a swapfile"
  sudo mkswap /swapfile
  
  log_info "Enable swap to use /swapfile"
  sudo swapon /swapfile
  
  log_info "Backup /etc/fstab"
  sudo cp /etc/fstab /etc/fstab_backup

  log_info "Log /swapfile into /etc/fstab"
  echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab

  log_info "Set up swapfile has been COMPLETED"
}

function setup_helmchartconfig_traefik() {
  log_info "Writing Traefik HelmChartConfig manifest"

  # Make sure the manifests directory exists
  sudo mkdir -p /var/lib/rancher/k3s/server/manifests

  # Write the HelmChartConfig manifest for Traefik
  sudo tee /var/lib/rancher/k3s/server/manifests/traefik-config.yaml >/dev/null <<'YAML'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    ports:
      web:
        nodePort: 30080
      websecure:
        nodePort: 30443
YAML

  if [ $? -eq 0 ]; then
    log_okay "Traefik HelmChartConfig written to /var/lib/rancher/k3s/server/manifests/traefik-config.yaml"
  else
    log_warn "Failed to write Traefik HelmChartConfig"
  fi
}


# Execute the list of actions
swapfile_setup
main_setup


