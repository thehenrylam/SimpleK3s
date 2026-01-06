#!/bin/bash

# Set bash flags 
set -euo pipefail 
# -u            : Error if an unset variable is referenced 
# -e            : Exits on ANY command failure 
# -o pipefail   : Make pipeline fail if any command in them fails 

function setup_swapfile() {
    FUNCTION_NAME="setup_swapfile"

    # Determine the swapfile allocation amount
    SWAPFILE_ALLOC_AMT="$1"

    # Exit if swapfile allocation input variable is EMPTY!
    if [ -z "$SWAPFILE_ALLOC_AMT" ]; then
        log_warn "[$FUNCTION_NAME] The swapfile allocation amount is empty: Skipping setup!"
        exit 0
    fi

    log_info "[$FUNCTION_NAME] Setup swapfile STARTING"
    log_info "[$FUNCTION_NAME] SWAPFILE allocation: $SWAPFILE_ALLOC_AMT"

    sudo fallocate -l "$SWAPFILE_ALLOC_AMT" /swapfile
    sudo chmod 0600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    sudo cp /etc/fstab /etc/fstab_backup
    echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab

    log_okay "[$FUNCTION_NAME] Setup swapfile COMPLETED"
}

setup_swapfile "$1"