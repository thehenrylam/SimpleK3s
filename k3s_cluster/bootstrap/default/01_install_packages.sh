#!/bin/bash

# Set bash flags 
set -euo pipefail 
# -u            : Error if an unset variable is referenced 
# -e            : Exits on ANY command failure 
# -o pipefail   : Make pipeline fail if any command in them fails 

SCRIPT_DIR=$(realpath $(dirname $0))

# Retrieve the common functions from common.sh (Calls upon simplek3s.env file)
source "$SCRIPT_DIR/common.sh"

function apt_update() {
    log_info "Kicking off update"

    # update package manager
    apt-get update -y || return 1

    log_okay "Completed update"
}

function apt_install_essential() {
    log_info "Kicking off install (mandatory)"

    # install essentials
    apt-get install -y \
        awscli \
        ca-certificates \
        gettext-base || return 1

    log_okay "Completed install (mandatory)"
}

function apt_install_nicetohave() {
    log_info "Kicking off install (nicetohave)"

    # install nice-to-haves
    apt-get install -y \
        fastfetch \
        htop || return 1

    log_okay "Completed install (nicetohave)"
}

log_info "$0: LAUNCHED"

apt_update || {
    log_fail "Failed update"
    exit 1
}

apt_install_essential || {
    log_fail "Failed to install (mandatory)"
    exit 1
}

apt_install_nicetohave || {
    log_fail "Failed install (nicetohave)"
    exit 1
}

log_okay "$0: COMPLETED"


