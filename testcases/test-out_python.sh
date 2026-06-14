#!/bin/bash
# Performs a general check on the Python scripts that is inside this project

set -euo pipefail

LOG_FILENAME="${1-test-out_python}"
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

# --- ruff ---

RUFF_PY_FILES=()

collect_py_files() {
    while IFS= read -r -d '' f; do
        RUFF_PY_FILES+=("$f")
    done < <(find "${REPO_ROOT}" -name "*.py" \
        -not -path "${REPO_ROOT}/_tmp/*" \
        -not -path "${REPO_ROOT}/venv/*" \
        -not -path "${REPO_ROOT}/*/.venv/*" \
        -print0)
}

list_py_files() {
    echo "Collected ${#RUFF_PY_FILES[@]} Python file(s):"
    printf '  %s\n' "${RUFF_PY_FILES[@]}"
}

ruff_check_all() {
    ruff check "${RUFF_PY_FILES[@]}"
}

ruff_format_check_all() {
    ruff format --check "${RUFF_PY_FILES[@]}"
}

check_ruff() {
    collect_py_files
    # list_py_files (Disabled, enable if we need to check the contents of RUFF_PY_FILES)
    run_check "ruff check (all *.py)" ruff_check_all
    run_check "ruff format --check (all *.py)" ruff_format_check_all
}

# --- main ---

echo "=== $(basename "${0}") (Starting) ==="
check_ruff
echo "=== $(basename "${0}") (Completed: Results Below) ==="

if [[ "$FAIL" -eq 0 ]]; then
    echo "All ${PASS} checks passed."
else
    echo "${PASS} passed, ${FAIL} failed."
    exit 1
fi
