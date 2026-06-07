#!/bin/bash

# Set bash flags 
set -euo pipefail 
# -u            : Error if an unset variable is referenced 
# -e            : Exits on ANY command failure 
# -o pipefail   : Make pipeline fail if any command in them fails 

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Retrieve the common functions from common.sh (Calls upon simplek3s.env file)
# shellcheck source=k3s_cluster/cluster_app/bootstrap/data/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

function apt_update() {
    log_info "Kicking off update"

    # update package manager
    apt-get update -y || return 1

    log_okay "Completed update"
}

function apt_install_essential() {
    log_info "Kicking off install (mandatory)"

    # Note: awscli and amazon-ssm-agent are NOT installed here.
    # They are assumed to be pre-installed before this script runs —
    # either baked into the AMI or provisioned by the cloud-init script.

    # install essentials
    # check-versions: ignore - ca-certificates and gettext-base are OS-level packages tied to the Debian release
    apt-get install -y \
        ca-certificates \
        gettext-base || return 1

    log_okay "Completed install (mandatory)"
}

function apt_install_nicetohave() {
    log_info "Kicking off install (nicetohave)"

    # install nice-to-haves
    # check-versions: ignore - fastfetch and htop are convenience utilities, version is not critical
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


