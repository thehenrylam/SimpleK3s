#!/bin/bash
# Performs a general check on the shell scripts that is inside this project

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

check_shellcheck

echo ""
if [[ "$FAIL" -eq 0 ]]; then
    echo "All ${PASS} checks passed."
else
    echo "${PASS} passed, ${FAIL} failed."
    exit 1
fi
