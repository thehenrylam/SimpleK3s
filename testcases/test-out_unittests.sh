#!/bin/bash
# Runs the unit tests for on-node verification logic.
#
# These are OFF-CLUSTER tests: pytest is a local/CI tool and never ships to a
# node. The code under test is stdlib-only and is exercised here against fakes,
# so a defect in a health check is caught before it can report a broken cluster
# as healthy — which is exactly how #156 reached production.

set -euo pipefail

LOG_FILENAME="${1-test-out_unittests}"
LOG_TIMESTAMP="${2-$(date +'%Y%m%d-%H%M%S')}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CURR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Logging ---
LOG_FILE="${CURR_ROOT}/${LOG_FILENAME}-${LOG_TIMESTAMP}.log"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 0644 "$LOG_FILE"

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
        printf '%s\n' "${output}" | tail -3
        ((PASS++)) || true
    else
        echo "[FAIL] ${label}"
        printf '%s\n' "${output}"
        ((FAIL++)) || true
    fi
}

pytest_all() {
    # Run from the repo root so pytest.ini's testpaths and pythonpath apply.
    (cd "${REPO_ROOT}" && pytest)
}

echo "=== $(basename "$0") (Starting) ==="

if ! command -v pytest &>/dev/null; then
    echo "[FAIL] pytest is not installed."
    echo "       Run ./toolchain/tc_testing_macos_install.sh"
    echo "=== $(basename "$0") (Completed: Results Below) ==="
    echo "1 check failed."
    exit 1
fi

run_check "pytest (unit tests for on-node verification)" pytest_all

echo "=== $(basename "$0") (Completed: Results Below) ==="
TOTAL=$((PASS + FAIL))
if [[ "$FAIL" -eq 0 ]]; then
    echo "All ${TOTAL} checks passed."
else
    echo "${PASS}/${TOTAL} checks passed, ${FAIL} failed."
    exit 1
fi
