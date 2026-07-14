#!/bin/bash

# Set bash flags
set -euo pipefail
# -u            : Error if an unset variable is referenced
# -e            : Exits on ANY command failure
# -o pipefail   : Make pipeline fail if any command in them fails

# Node-local setup only (bts_01..04). Does NOT stage manifests or run
# converge_actions — use this for day-2 node replacement where the cluster
# is already running and only the node itself needs to be (re-)initialized.
#
# Usage: node_init-essential.sh <COUNT_INDEX> <CLUSTER_TYPE>
#   COUNT_INDEX   0-based index of this node within its plane
#   CLUSTER_TYPE  "controlplane" or "agentplane"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DEFAULT_LOG_FILE="${SCRIPT_DIR}/simplek3s-init_$(date +'%Y%m%d%H%M%S%3N').log"
LOG_FILE="${LOG_FILE:-$DEFAULT_LOG_FILE}"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 0644 "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== $(basename "$0") starting ==="
echo "LOG_FILE=$LOG_FILE"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/simplek3s.env"
# shellcheck source=k3s_cluster/cluster_app/bootstrap/data/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=k3s_cluster/cluster_app/bootstrap/data/lib/providers/aws.sh
source "$SCRIPT_DIR/lib/providers/aws.sh"

function usage() {
    echo "Usage: $(basename "$0") <COUNT_INDEX> <CLUSTER_TYPE>" >&2
    exit 2
}

COUNT_INDEX="$1"
CLUSTER_TYPE="${2:-}"

if [[ -z "$COUNT_INDEX" || ! "$COUNT_INDEX" =~ ^[0-9]+$ ]]; then
    usage
fi

log_info "$0: LAUNCHED"

case "$CLUSTER_TYPE" in
    controlplane)
        log_info "Node-local setup: Control Plane (index ${COUNT_INDEX})"

        "$SCRIPT_DIR/bts_01_install_packages.sh" || exit 1
        "$SCRIPT_DIR/bts_02_setup_swapfile.sh" "$SWAPFILE_ALLOC_AMT" || exit 1

        local_node_type=$([ "$COUNT_INDEX" -eq 0 ] && echo "controller" || echo "server")
        "$SCRIPT_DIR/bts_03_install_k3s.sh" "$local_node_type" || exit 1

        "$SCRIPT_DIR/bts_04_setup_longhorn_diskpools.sh" "controlplane" || exit 1

        log_okay "Node-local setup: Control Plane - COMPLETED"
        ;;
    agentplane)
        log_info "Node-local setup: Agent Plane (index ${COUNT_INDEX})"

        "$SCRIPT_DIR/bts_01_install_packages.sh" || exit 1
        "$SCRIPT_DIR/bts_02_setup_swapfile.sh" "$SWAPFILE_ALLOC_AMT" || exit 1
        "$SCRIPT_DIR/bts_03_install_k3s.sh" "agent" || exit 1
        "$SCRIPT_DIR/bts_04_setup_longhorn_diskpools.sh" "agentplane" || exit 1

        log_okay "Node-local setup: Agent Plane - COMPLETED"
        ;;
    *)
        usage
        ;;
esac

echo "=== $(basename "$0") completed ==="
