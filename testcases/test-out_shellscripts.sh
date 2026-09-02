#!/bin/bash
# Performs a general check on the shell scripts that is inside this project

set -euo pipefail

LOG_FILENAME="${1-test-out_shellscripts}"
LOG_TIMESTAMP="${2-$(date +'%Y%m%d-%H%M%S')}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CURR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Logging ---
# set up 
LOG_FILE="${CURR_ROOT}/${LOG_FILENAME}-${LOG_TIMESTAMP}.log"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 0644 "$LOG_FILE"

# Send all output (stdout+stderr) to:
#  - your log file
#  - cloud-init output log (via console)
#  - syslog (tagged)
exec > >(while IFS= read -r line; do printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$line"; done \
    | tee -a "$LOG_FILE" >(logger -t "${LOG_FILENAME}")) 2>&1
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

# *.sh, plus extensionless executables carrying a sh/bash shebang. The second
# pass exists because the operator entry point is `sk3s` — named without an
# extension so it reads as a command — and a glob on *.sh would leave the one
# file everybody runs as the only one nothing checks.
shellcheck_all() {
    {
        find "${REPO_ROOT}" -name "*.sh" -not -path "${REPO_ROOT}/_tmp/*" -print0
        find "${REPO_ROOT}" -type f -perm -u+x ! -name "*.*" \
            -not -path "${REPO_ROOT}/.git/*" \
            -not -path "${REPO_ROOT}/_tmp/*" \
            -not -path "*/.terraform/*" \
            -exec sh -c 'head -n 1 "${1}" | grep -qE "^#!.*/(env +)?(ba)?sh$"' _ {} \; \
            -print0
    } | xargs -0 shellcheck -x -S warning
}

check_shellcheck() {
    run_check "shellcheck (all *.sh + shebang scripts)" shellcheck_all
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
