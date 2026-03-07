#!/bin/bash

# Set bash flags 
set -euo pipefail 
# -u            : Error if an unset variable is referenced 
# -e            : Exits on ANY command failure 
# -o pipefail   : Make pipeline fail if any command in them fails 

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Retrieve the common functions from common.sh (Calls upon simplek3s.env file)
source "$SCRIPT_DIR/lib/common.sh"

# The index of the current node 
# If COUNT_INDEX == 0 then its a controller, 
# otherwise its a server node part of the HA control-plane)
COUNT_INDEX="$1"
if [[ -z "$COUNT_INDEX" || ! "$COUNT_INDEX" =~ ^[0-9]+$ ]]; then
    echo "Usage: $(basename "$0") <COUNT_INDEX>" >&2
    exit 2
fi

echo "=== $(basename $0) starting ==="

# Execute additional scripts for the controller
if [[ "$COUNT_INDEX" -eq 0 ]]; then
    log_info "Initializing subsystems"
    # Apply the configs of Traefik
    if [ -f "$SCRIPT_DIR/04_apply_traefik.sh" ]; then
        "$SCRIPT_DIR/04_apply_traefik.sh" || exit 1
    fi

    # Apply Kyverno (MUST be first Add-On to be applied)
    if [ -f "$SCRIPT_DIR/05_apply_kyverno.sh" ]; then
        "$SCRIPT_DIR/05_apply_kyverno.sh" || exit 1
    fi

    # Apply External Secrets
    if [ -f "$SCRIPT_DIR/05_apply_external-secrets.sh" ]; then
        "$SCRIPT_DIR/05_apply_external-secrets.sh" || exit 1
    fi

    # Apply Descheduler
    if [ -f "$SCRIPT_DIR/05_apply_descheduler.sh" ]; then
        "$SCRIPT_DIR/05_apply_descheduler.sh" || exit 1
    fi
    log_okay "Initialized subsystems"
else
    log_info "COUNT_INDEX is NOT 0; Skipping initialization of subsystems"
fi

echo "=== $(basename $0) completed ==="
