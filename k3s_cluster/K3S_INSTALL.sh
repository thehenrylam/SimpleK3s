#!/bin/bash

# Set bash flags 
set -euo pipefail 
# -u            : Error if an unset variable is referenced 
# -e            : Exits on ANY command failure 
# -o pipefail   : Make pipeline fail if any command in them fails 

# Variables surrounded with "$" and "{}" is set by a templatefile(...) command 
# Variables referenced externally:
#   - count_index         : The index number of the initialized machine 
#   - swapfile_alloc_amt  : The swapfile allocation amount (e.g. "2G")
#   - k3s_secret_token    : The secret token for initializing K3s and referencing the controller host  
#   - controller_host     : The K3s controller host (represented by IP address, usually cloud private IP) 
#   - nodeport_http       : The nodeport of the HTTP port (Allow HTTP access from the K3s pod) 
#   - nodeport_https      : The nodeport of the HTTPS port (Allow HTTPS access from the K3s pod) 

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
    log_info "K3S_TOKEN: ${k3s_secret_token}"
    log_info "CONTROLLER_HOST ${controller_host}"

    log_info "PRIMARY node is being set up!"
    # Set up first server
    curl -sfL https://get.k3s.io | K3S_TOKEN="${k3s_secret_token}" sh -s - server \
      --cluster-init \
      --tls-san="${controller_host}" 2>&1 | tee -a $LOG_FILE # Optional, needed if using a fixed registration address

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
    log_info "K3S_TOKEN: ${k3s_secret_token}"
    log_info "CONTROLLER_HOST: ${controller_host}"

    log_info "Waiting for the PRIMARY node to get set up"
    # Wait until the master node is up
    ETCD_0=down
    while [[ "$ETCD_0" == "down" ]]; do 
      curl --connect-timeout 3 -k https://${controller_host}:6443 && ETCD_0=up || ETCD_0=down
    done
    if [[ "$ETCD_0" == "up" ]]; then
      log_okay "PRIMARY node is now up! (ETCD_0: $ETCD_0)"
    else
      log_fail "PRIMARY node is still down! (ETCD_0: $ETCD_0)"
    fi 

    log_info "SECONDARY node is being set up!"
    # Set up agent server
    curl -sfL https://get.k3s.io | K3S_TOKEN="${k3s_secret_token}" sh -s - server \
      --server https://${controller_host}:6443 \
      --tls-san=${controller_host} 2>&1 | tee -a $LOG_FILE # Optional, needed if using a fixed registration address
    
    if [ $? -eq 0 ]; then
      log_okay "SECONDARY node has been set up!"
    else
      log_fail "SECONDARY node has not been set up correctly!"
    fi 

  fi

  log_info "Setup for node: ${count_index} has been COMPLETED"
}

function restart_coredns() {
  # Restart CoreDNS to help address stale coreDNS service issues
  # Why do we do this?
  #  - CoreDNS has a habit of being stale on initial cluster setup
  #  - Restarting the coreDNS would help new pods to resolve DNS properly
  log_info "Restarting CoreDNS (address stale CoreDNS service issues)"
  log_info "Determine if current node is PRIMARY node"
  if [ ${count_index} -eq 0 ]; then
    log_info "Current node is PRIMARY node: Proceed to restart CoreDNS"

    # Wait until CoreDNS deployment is available
    log_info "Waiting for CoreDNS deployment to be available"
    CORE_DNS_READY=false
    for i in $(seq 1 36); do # Wait up to 3 minutes (36 attempts x 5 sec = 180 sec)
      sudo kubectl -n kube-system get deploy/coredns >/dev/null 2>&1 && CORE_DNS_READY=true && break
      log_info "CoreDNS deployment is not yet available: Waiting..."
      sleep 5
    done

    # If CoreDNS isn't available after waiting, then abort the operation
    if [ "$CORE_DNS_READY" = false ]; then
      log_fail "CoreDNS deployment is still not available after waiting: Aborting CoreDNS restart"
      exit 1
    fi

    # Kick off CoreDNS restart
    log_info "Kicking off CoreDNS restart now"
    sudo kubectl -n kube-system rollout restart deploy/coredns
    if [ $? -eq 0 ]; then
      log_okay "CoreDNS restart has been kicked off successfully"
    else
      log_warn "CoreDNS restart may have failed to start, continue to monitor rollout status"
    fi

    # Wait until CoreDNS deployment is successfully rolled out
    log_info "Waiting for CoreDNS deployment to be successfully rolled out (3 minutes)"
    sudo kubectl -n kube-system rollout status deploy/coredns --timeout=3m
    if [ $? -eq 0 ]; then
      log_okay "CoreDNS deployment has been successfully rolled out!"
    else
      log_fail "CoreDNS deployment failed to roll out within the timeout period (3 minutes)"
      exit 1
    fi

  else
    log_info "Current node is not PRIMARY node: Skip CoreDNS restart"
  fi
}

### SWAPFILE SETUP ###
function swapfile_setup() {
  log_info "Set up swapfile has now STARTED"

  log_info "Allocating ${swapfile_alloc_amt} to /swapfile"
  sudo fallocate -l "${swapfile_alloc_amt}" /swapfile
  
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
  sudo tee /var/lib/rancher/k3s/server/manifests/traefik-config.yaml >/dev/null <<YAML
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    ports:
      web:
        nodePort: ${nodeport_http}
      websecure:
        nodePort: ${nodeport_https}
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
### Temporarily Disabled # restart_coredns

