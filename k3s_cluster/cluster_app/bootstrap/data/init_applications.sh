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
    log_info "Initializing applications"
    # Optional: Apply the ArgoCD application
    if [ -f "$SCRIPT_DIR/app_argocd.sh" ]; then
        "$SCRIPT_DIR/app_argocd.sh" || exit 1
    fi 

    # Optional: Apply the Monitoring application
    if [ -f "$SCRIPT_DIR/app_monitoring.sh" ]; then
        "$SCRIPT_DIR/app_monitoring.sh" || exit 1
    fi
    log_okay "Initialized applications"
else
    log_info "COUNT_INDEX is NOT 0; Skipping initialization of applications"
fi

echo "=== $(basename $0) completed ==="
