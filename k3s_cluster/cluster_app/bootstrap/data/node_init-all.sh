#!/bin/bash

# Set bash flags
set -euo pipefail
# -u            : Error if an unset variable is referenced
# -e            : Exits on ANY command failure
# -o pipefail   : Make pipeline fail if any command in them fails

# Full node initialisation: package install, swap, K3s, disks, and (on node-0)
# manifest staging + post-convergence actions.
#
# Usage: node_init-all.sh <COUNT_INDEX> <CLUSTER_TYPE> [--no-refresh]
#   COUNT_INDEX    0-based index of this node within its plane
#   CLUSTER_TYPE   "controlplane" or "agentplane"
#   --no-refresh   Skip the S3 sync at startup (cloudinit already has fresh files)
#
# By default this script calls node_refresh-bootstrap-files.sh first so that
# re-runs via SSM always pick up the latest files from S3. Pass --no-refresh
# to skip the sync (e.g. when cloud-init has just synced everything).

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
echo "=== $(basename "$0") starting ==="
echo "LOG_FILE=$LOG_FILE"

# Retrieve all of the needed environment variables from this file
# shellcheck disable=SC1091
source "$SCRIPT_DIR/simplek3s.env"
# Retrieve the common functions from common.sh
# shellcheck source=k3s_cluster/cluster_app/bootstrap/data/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# Retrieve the AWS specific functions from aws.sh
# shellcheck source=k3s_cluster/cluster_app/bootstrap/data/lib/providers/aws.sh
source "$SCRIPT_DIR/lib/providers/aws.sh"


# Display usage
function usage() {
    echo "Usage: $(basename "$0") <COUNT_INDEX> <CLUSTER_TYPE> [--no-refresh]" >&2
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
    local NODE_TYPE
    NODE_TYPE=$([ "$COUNT_INDEX" -eq 0 ] && echo "controller" || echo "server")
    "$SCRIPT_DIR/bts_03_install_k3s.sh" "$NODE_TYPE" || exit 1

    "$SCRIPT_DIR/bts_04_setup_longhorn_diskpools.sh" "controlplane" || exit 1

    # Node 0 stages ALL subsystem/application manifests at once and lets the
    # cluster converge (the K3s deploy controller retries until dependencies
    # are up). The only post-staging imperative work lives in converge_actions.
    if [[ "$COUNT_INDEX" -eq 0 ]]; then
        "$SCRIPT_DIR/bts_05_stage_manifests.sh" || exit 1

        "$SCRIPT_DIR/converge_actions.sh" || exit 1
    else
        log_info "COUNT_INDEX is NOT 0; Skipping manifest staging"
    fi
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

    "$SCRIPT_DIR/bts_04_setup_longhorn_diskpools.sh" "agentplane" || exit 1
}


# Parse args: <COUNT_INDEX> <CLUSTER_TYPE> [--no-refresh]
COUNT_INDEX="${1:-}"
CLUSTER_TYPE="${2:-}"
NO_REFRESH="${3:-}"

if [[ -z "$COUNT_INDEX" || ! "$COUNT_INDEX" =~ ^[0-9]+$ ]]; then
    usage
fi
if [[ -n "$NO_REFRESH" && "$NO_REFRESH" != "--no-refresh" ]]; then
    usage
fi

# Sync the latest bootstrap files from S3 unless --no-refresh was passed.
# cloud-init calls this with --no-refresh (it already synced everything);
# SSM re-runs omit the flag so stale on-disk files are never used.
if [[ -z "$NO_REFRESH" ]]; then
    log_info "Refreshing bootstrap files from S3..."
    "$SCRIPT_DIR/node_refresh-bootstrap-files.sh" || {
        log_fail "Failed to refresh bootstrap files"
        exit 1
    }
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

echo "=== $(basename "$0") completed ==="
