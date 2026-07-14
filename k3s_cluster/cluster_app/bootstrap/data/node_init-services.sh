#!/bin/bash

# Set bash flags
set -euo pipefail
# -u            : Error if an unset variable is referenced
# -e            : Exits on ANY command failure
# -o pipefail   : Make pipeline fail if any command in them fails

# Stages all manifests and runs post-convergence actions (bts_05 + converge_actions).
# Run this on node-0 to apply a manifest update after node_refresh-bootstrap-files.sh
# has pulled the latest files from S3.
#
# This is the Step 3 update trigger:
#   node_refresh-bootstrap-files.sh && node_init-services.sh
#
# Idempotent: the K3s deploy controller re-applies only changed manifests;
# identical content is skipped.

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

log_info "$0: LAUNCHED"

"$SCRIPT_DIR/bts_05_stage_manifests.sh" || {
    log_fail "Failed to stage manifests"
    exit 1
}

"$SCRIPT_DIR/converge_actions.sh" || {
    log_fail "Failed to run converge actions"
    exit 1
}

log_okay "$0: COMPLETED"
echo "=== $(basename "$0") completed ==="
