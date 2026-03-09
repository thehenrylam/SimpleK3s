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


# Display usage
function usage() {
    echo "Usage: $(basename "$0") <COUNT_INDEX> <CLUSTER_TYPE>" >&2
    exit 2
}

# Setup control plane
function setup_control_plane() {
    local COUNT_INDEX="$1"

    # Install the packages
    "$SCRIPT_DIR/bts_01_install_packages.sh" || exit 1

    # Setup the swapfile (SWAPFILE_ALLOC_AMT is provided from simplek3s.env file)
    "$SCRIPT_DIR/bts_02_setup_swapfile.sh" "$SWAPFILE_ALLOC_AMT" || exit 1

    # Setup the k3s (if COUNT_INDEX == 0 then install as "controller", otherwise install as "server")
    local NODE_TYPE=$([ $COUNT_INDEX -eq 0 ] && echo "controller" || echo "server")
    "$SCRIPT_DIR/bts_03_install_k3s.sh" "$NODE_TYPE" || exit 1

    "$SCRIPT_DIR/init_subsystems.sh" "$COUNT_INDEX" || exit 1

    "$SCRIPT_DIR/init_applications.sh" "$COUNT_INDEX" || exit 1
}

# Setup agent
function setup_agent_plane() {
    local COUNT_INDEX="$1"

    # Install the packages
    "$SCRIPT_DIR/bts_01_install_packages.sh" || exit 1

    # Setup the swapfile (SWAPFILE_ALLOC_AMT is provided from simplek3s.env file)
    "$SCRIPT_DIR/bts_02_setup_swapfile.sh" "$SWAPFILE_ALLOC_AMT" || exit 1

    # Setup the k3s (agent)
    local NODE_TYPE="agent"
    "$SCRIPT_DIR/bts_03_install_k3s.sh" "$NODE_TYPE" || exit 1
}


# The index of the current node 
# If COUNT_INDEX == 0 then its a controller, 
# otherwise its a server node part of the HA control plane)
COUNT_INDEX="$1"
CLUSTER_TYPE="$2"
if [[ -z "$COUNT_INDEX" || ! "$COUNT_INDEX" =~ ^[0-9]+$ ]]; then
    usage # Display the usage
fi

# Perform node type
case "$CLUSTER_TYPE" in
    controlplane) 
        log_info "Install K3s: Control Plane"
        setup_control_plane "$COUNT_INDEX" || {
            log_fail "Failed to set up K3s: Control Plane"
            exit 1
        }
        log_okay "Install K3s: Control Plane - COMPLETED"
        ;;
    agentplane)
        log_info "Install K3s: Agent Plane"
        setup_agent_plane "$COUNT_INDEX" || {
            log_fail "Failed to set up K3s: Agent Plane"
            exit 1
        }
        log_okay "Install K3s: Agent Plane - COMPLETED"
        ;;
    *) 
        usage # Display the usage
        ;;
esac

echo "=== $(basename $0) completed ==="
