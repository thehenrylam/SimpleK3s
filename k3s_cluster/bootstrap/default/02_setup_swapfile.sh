#!/bin/bash

# Set bash flags 
set -euo pipefail 
# -u            : Error if an unset variable is referenced 
# -e            : Exits on ANY command failure 
# -o pipefail   : Make pipeline fail if any command in them fails 

SCRIPT_DIR=$(realpath $(dirname $0))

ALLOCATION_AMOUNT="${1}"

# Retrieve the common functions from common.sh (Calls upon simplek3s.env file)
source "$SCRIPT_DIR/common.sh"

function setup_swapfile() {
    local allocation_amount="${1}"

    local swapfile_filepath="/swapfile"
    local fstab_filepath="/etc/fstab"

    log_info "Set up swapfile has now STARTED"

    # Check if swapfile exists, and gracefully exit if it already does 
    # This helps in case setup process needs to be rerun for troubleshooting
    if [ -f "$swapfile_filepath" ]; then
        log_okay "Swap file '$swapfile_filepath' has already been set up, skipping setup"
        return 0
    fi 

    log_info "Allocating '$allocation_amount' to $swapfile_filepath"
    sudo fallocate -l "$allocation_amount" $swapfile_filepath || return 1
    
    log_info "Setting up permissions on $swapfile_filepath"
    sudo chmod 0600 $swapfile_filepath || return 1
    
    log_info "Make $swapfile_filepath into a swapfile"
    sudo mkswap $swapfile_filepath || return 1
    
    log_info "Enable swap to use $swapfile_filepath"
    sudo swapon $swapfile_filepath || return 1
    
    log_info "Backup $fstab_filepath"
    sudo cp "$fstab_filepath" "${fstab_filepath}_backup" || return 1

    log_info "Log $swapfile_filepath into $fstab_filepath"
    echo "$swapfile_filepath none swap sw 0 0" | sudo tee -a "$fstab_filepath" || return 1

    log_okay "Set up swapfile has been COMPLETED"
}

log_info "$0: LAUNCHED"

setup_swapfile "$ALLOCATION_AMOUNT" || {
    log_fail "Failed to set up swapfile"
    exit 1
}

log_okay "$0: COMPLETED"


