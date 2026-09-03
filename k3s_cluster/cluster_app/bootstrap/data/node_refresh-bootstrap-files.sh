#!/bin/bash

# Set bash flags
set -euo pipefail
# -u            : Error if an unset variable is referenced
# -e            : Exits on ANY command failure
# -o pipefail   : Make pipeline fail if any command in them fails

# Syncs the latest bootstrap files from S3 to the node's bootstrap directory
# and ensures all scripts are executable. Idempotent and safe to run at any time.
#
# Used as the first step in node_init-all.sh (unless --no-refresh is passed)
# and as the standalone pre-step for node_init-services.sh in the Step 3
# update path: node_refresh-bootstrap-files.sh && node_init-services.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# Provides: S3_BUCKET_NAME, BOOTSTRAP_DIR, AWS_REGION (via simplek3s.env)

log_info "$0: LAUNCHED"

log_info "Syncing bootstrap files: s3://${S3_BUCKET_NAME}/ -> ${BOOTSTRAP_DIR}"
aws s3 sync "s3://${S3_BUCKET_NAME}/" "${BOOTSTRAP_DIR}" \
    --region "${AWS_REGION}" \
    --only-show-errors || {
    log_fail "Failed to sync bootstrap files from S3"
    exit 1
}

log_info "Setting execute permissions on bootstrap scripts..."
find "${BOOTSTRAP_DIR}" -type f -name "*.sh" -exec chmod u+x {} \;
find "${BOOTSTRAP_DIR}" -type f -name "*.py" -exec chmod u+x {} \;

# Record the generation LAST — after the sync and the chmod have both succeeded.
# The stamp answers "what did this node successfully take from S3", so it must
# never advance past a partial refresh.
log_info "Recording the bootstrap generation..."
if GENERATION="$(s3_generation)"; then
    printf '%s\n' "${GENERATION}" > "${GENERATION_FILE}"
    log_okay "Bootstrap generation: ${GENERATION}"
else
    # Not fatal: the files themselves synced. Verify reports the generation as
    # unknown, which is honest — better than leaving a stale stamp that would
    # read as "current".
    log_warn "Could not compute the bootstrap generation; stamp left unchanged"
fi

log_okay "$0: COMPLETED"
