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

# Captured BEFORE the sync: afterwards the stamp is overwritten, and "what did
# this node move from" is the question a pull report has to answer.
GENERATION_BEFORE="$(recorded_generation)" || GENERATION_BEFORE=""

log_info "Syncing bootstrap files: s3://${S3_BUCKET_NAME}/ -> ${BOOTSTRAP_DIR}"

# --only-show-errors was suppressing the per-file list, which is the ONLY record
# of what actually changed: aws computes it and we were discarding it. Kept
# --no-progress so the transfer bar does not end up in the log, and the output is
# captured rather than streamed so it can be both printed and summarised.
#
# Declared before assignment: `local`/assignment on one line would mask the
# command's exit status behind the assignment's own.
SYNC_OUTPUT=""
SYNC_STATUS=0
SYNC_FLAGS=(--region "${AWS_REGION}" --no-progress)
if is_dry_run; then
    # --dryrun prints the same "download:" lines it would have acted on, so the
    # preview and the real run are parsed by identical code.
    SYNC_FLAGS+=(--dryrun)
    log_info "DRY RUN: no files will be written"
fi
SYNC_OUTPUT="$(aws s3 sync "s3://${S3_BUCKET_NAME}/" "${BOOTSTRAP_DIR}" \
    "${SYNC_FLAGS[@]}" 2>&1)" || SYNC_STATUS=$?

# Only when there is something to show: an empty capture would print a bare
# newline, which reads as a gap in the log for the commonest case of all.
if [[ -n "${SYNC_OUTPUT}" ]]; then
    printf '%s\n' "${SYNC_OUTPUT}"
fi

if (( SYNC_STATUS != 0 )); then
    log_fail "Failed to sync bootstrap files from S3"
    pull_report_kv step sync result failed detail "aws s3 sync exited ${SYNC_STATUS}"
    exit 1
fi

# "download: s3://bucket/key to /local/path" -> "key". A sync that changed
# nothing prints no such lines, which is the difference between "nothing to do"
# and "something happened" that the old output could not express.
SYNC_FILES="$(printf '%s\n' "${SYNC_OUTPUT}" \
    | sed -n 's|^(dryrun) download: s3://[^/]*/\([^ ]*\) to .*|\1|p;s|^download: s3://[^/]*/\([^ ]*\) to .*|\1|p' | sort)"
SYNC_COUNT="$(printf '%s' "${SYNC_FILES}" | grep -c . || true)"
log_info "Synced ${SYNC_COUNT} changed file(s)"
pull_report_kv step sync result ok changed "${SYNC_COUNT}" \
    files "$(printf '%s' "${SYNC_FILES}" | json_array)"

# Everything past this point writes. A preview stops here, but still reports the
# generation it WOULD move to — s3_generation reads the bucket, not local files,
# so it is answerable without having synced anything.
if is_dry_run; then
    GEN_WOULD_BE="$(s3_generation)" || GEN_WOULD_BE="unknown"
    pull_report_kv step generation before "${GENERATION_BEFORE:-unknown}" after "${GEN_WOULD_BE}"
    log_okay "$0: COMPLETED (dry run — nothing changed)"
    exit 0
fi

log_info "Setting execute permissions on bootstrap scripts..."
find "${BOOTSTRAP_DIR}" -type f -name "*.sh" -exec chmod u+x {} \;
find "${BOOTSTRAP_DIR}" -type f -name "*.py" -exec chmod u+x {} \;

# Record the generation LAST — after the sync and the chmod have both succeeded.
# The stamp answers "what did this node successfully take from S3", so it must
# never advance past a partial refresh.
log_info "Recording the bootstrap generation..."
if GENERATION="$(record_generation)"; then
    log_okay "Bootstrap generation: ${GENERATION}"
    pull_report_kv step generation before "${GENERATION_BEFORE:-unknown}" after "${GENERATION}"
else
    # Not fatal: the files themselves synced. Verify reports the generation as
    # unknown, which is honest — better than leaving a stale stamp that would
    # read as "current".
    log_warn "Could not compute the bootstrap generation; stamp left unchanged"
    pull_report_kv step generation before "${GENERATION_BEFORE:-unknown}" after unknown
fi

log_okay "$0: COMPLETED"
