#!/bin/bash

# Set bash flags
set -euo pipefail
# -u            : Error if an unset variable is referenced
# -e            : Exits on ANY command failure
# -o pipefail   : Make pipeline fail if any command in them fails

# Full node initialisation: package install, swap, K3s, disks, and — on the node
# that claims staging ownership — manifest staging + post-convergence actions.
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
export LOG_FILE  # Export so child node_*.sh scripts share this log instead of creating their own
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

# Setup control plane: node-local setup (via node_init-essential.sh), then on
# the node that claims staging ownership, manifest staging + converge (via
# node_init-services.sh).
function setup_control_plane() {
    local COUNT_INDEX="$1"

    "$SCRIPT_DIR/node_init-essential.sh" "$COUNT_INDEX" "controlplane" || exit 1

    # The claim talks to the API, so it cannot run before k3s answers. bts_05
    # waits too, but that wait is downstream of the decision made here.
    wait_for_k3s_api || {
        log_fail "K3s API never became reachable; cannot determine staging ownership"
        exit 1
    }

    # Ownership is claimed from the cluster, not assigned by index. The old gate
    # was COUNT_INDEX -eq 0, which made node 0 structurally special for work any
    # control-plane node can do.
    local INSTANCE_ID
    INSTANCE_ID="$(get_ec2_instance_id)" || INSTANCE_ID=""

    local CLAIM_STATUS=0
    claim_staging_ownership "$INSTANCE_ID" || CLAIM_STATUS=$?

    case "$CLAIM_STATUS" in
        0)
            "$SCRIPT_DIR/node_init-services.sh" || exit 1
            ;;
        1)
            log_info "Another node owns manifest staging; skipping"
            ;;
        *)
            # Not knowing who owns staging is a failure, not a reason to skip.
            # Skipping here on a first boot would leave a cluster with no staged
            # manifests at all, reported exactly like a healthy non-owner.
            log_fail "Could not determine staging ownership"
            exit 1
            ;;
    esac
}

# Setup agent: node-local setup only (via node_init-essential.sh).
function setup_agent_plane() {
    local COUNT_INDEX="$1"
    "$SCRIPT_DIR/node_init-essential.sh" "$COUNT_INDEX" "agentplane" || exit 1
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
else
    # cloud-init has just downloaded the bucket, so this node IS at the current
    # generation — it simply has no record of it, because the stamp is written
    # by the refresh step that --no-refresh skips. Without this, every freshly
    # booted node reports "no stamp" while being perfectly current, which is
    # indistinguishable from a node that has genuinely never been refreshed.
    log_info "Recording the bootstrap generation (cloud-init already synced)..."
    if GENERATION="$(record_generation)"; then
        log_okay "Bootstrap generation: ${GENERATION}"
    else
        log_warn "Could not compute the bootstrap generation; node will report unknown"
    fi
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
