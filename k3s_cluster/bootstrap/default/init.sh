#!/bin/bash

# Set bash flags 
set -euo pipefail 
# -u            : Error if an unset variable is referenced 
# -e            : Exits on ANY command failure 
# -o pipefail   : Make pipeline fail if any command in them fails 

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Set up log file
DEFAULT_LOG_FILE="${SCRIPT_DIR}/simplek3s-init_$(date +'%Y%m%d%H%M%S%3N').log"
LOG_FILE="${LOG_FILE:-$DEFAULT_LOG_FILE}"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 0644 "$LOG_FILE"

# Redirect script's output to the log file 
exec > >(tee -a "$LOG_FILE") 2>&1
# Announce to that this script will start
echo "=== $(basename $0) starting ==="
echo "LOG_FILE=$LOG_FILE"

# Retrieve all of the needed environment variables from this file
source "$SCRIPT_DIR/simplek3s.env"
# Retrieve the common functions from common.sh
source "$SCRIPT_DIR/lib/common.sh"
# Retrieve the AWS specific functions from aws.sh
source "$SCRIPT_DIR/lib/providers/aws.sh"

# The index of the current node 
# If COUNT_INDEX == 0 then its a controller, 
# otherwise its a server node part of the HA control-plane)
COUNT_INDEX="$1"
if [[ -z "$COUNT_INDEX" || ! "$COUNT_INDEX" =~ ^[0-9]+$ ]]; then
    echo "Usage: $(basename "$0") <COUNT_INDEX>" >&2
    exit 2
fi

# Install the packages
"$SCRIPT_DIR/01_install_packages.sh" || exit 1

# Setup the swapfile (SWAPFILE_ALLOC_AMT is provided from simplek3s.env file)
"$SCRIPT_DIR/02_setup_swapfile.sh" "$SWAPFILE_ALLOC_AMT" || exit 1

# Setup the k3s (if COUNT_INDEX == 0 then install as "controller", otherwise install as "server")
NODE_TYPE=$([ $COUNT_INDEX -eq 0 ] && echo "controller" || echo "server")
"$SCRIPT_DIR/03_install_k3s.sh" "$NODE_TYPE" || exit 1

# Execute additional scripts for the controller
if [[ "$COUNT_INDEX" -eq 0 ]]; then
    # Apply the configs of Traefik
    "$SCRIPT_DIR/04_apply_traefik.sh" || exit 1

    # Apply External Secrets
    "$SCRIPT_DIR/05_apply_external-secrets.sh" || exit 1

    # Optional: Apply the ArgoCD application
    if [ -f "$SCRIPT_DIR/optional_argocd.sh" ]; then
        "$SCRIPT_DIR/optional_argocd.sh" || exit 1
    fi 

    # Optional: Apply the Monitoring application
    if [ -f "$SCRIPT_DIR/optional_monitoring.sh" ]; then
        "$SCRIPT_DIR/optional_monitoring.sh" || exit 1
    fi 
fi


