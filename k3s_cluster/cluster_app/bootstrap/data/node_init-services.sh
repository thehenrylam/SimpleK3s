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

# If LOG_FILE is already set (exported by a parent script such as node_init-all.sh),
# skip the exec redirect — the parent's tee is already capturing all output.
if [[ -z "${LOG_FILE:-}" ]]; then
    LOG_FILE="${SCRIPT_DIR}/simplek3s-init_$(date +'%Y%m%d%H%M%S%3N').log"
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 0644 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "LOG_FILE=$LOG_FILE"
fi
echo "=== $(basename "$0") starting ==="

# shellcheck disable=SC1091
source "$SCRIPT_DIR/simplek3s.env"
# shellcheck source=k3s_cluster/cluster_app/bootstrap/data/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

log_info "$0: LAUNCHED"

"$SCRIPT_DIR/bts_05_stage_manifests.sh" || {
    log_fail "Failed to stage manifests"
    exit 1
}

# Converge actions restart live deployments (argocd-server, the Tailscale
# operator), so a preview reports them rather than running them. They are named
# individually because "converge actions" tells an operator nothing about what
# is at risk.
if is_dry_run; then
    log_info "DRY RUN: skipping converge actions"
    pull_report_kv step action name converge_actions performed false \
        detail "may restart argocd-server and the tailscale operator"
else
    "$SCRIPT_DIR/converge_actions.sh" || {
        log_fail "Failed to run converge actions"
        exit 1
    }
fi

log_okay "$0: COMPLETED"
echo "=== $(basename "$0") completed ==="
