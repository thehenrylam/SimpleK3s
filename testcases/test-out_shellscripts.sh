#!/bin/bash
# Performs a general check on the shell scripts that is inside this project

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CURR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Logging ---
# set up 
LOG_FILE="${CURR_ROOT}/test_check_all_shellscripts-$(date +'%Y%m%d-%H%M%S').log"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 0644 "$LOG_FILE"

# Send all output (stdout+stderr) to:
#  - your log file
#  - cloud-init output log (via console)
#  - syslog (tagged)
exec > >(while IFS= read -r line; do printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$line"; done \
    | tee -a "$LOG_FILE" >(logger -t test_check_all_shellscripts)) 2>&1
# --- Logging ---

PASS=0
FAIL=0

run_check() {
    local label="$1"
    shift
    local output
    if output=$("$@" 2>&1); then
        echo "[OK]   ${label}"
        ((PASS++)) || true
    else
        echo "[FAIL] ${label}"
        printf '%s\n' "${output}"
        ((FAIL++)) || true
    fi
}

# --- shellcheck ---

shellcheck_all() {
    find "${REPO_ROOT}" -name "*.sh" -not -path "${REPO_ROOT}/_tmp/*" -print0 \
        | xargs -0 shellcheck -x -S warning
}

check_shellcheck() {
    run_check "shellcheck (all *.sh)" shellcheck_all
}

# --- main ---

echo "=== $(basename "${0}") (Starting) ==="
check_shellcheck
echo "=== $(basename "${0}") (Completed: Results Below) ==="

if [[ "$FAIL" -eq 0 ]]; then
    echo "All ${PASS} checks passed."
else
    echo "${PASS} passed, ${FAIL} failed."
    exit 1
fi
