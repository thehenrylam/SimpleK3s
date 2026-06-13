#!/bin/bash

set -euo pipefail

LOG_FILENAME="${1-test-out_terraform}"
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

# Runs a command, captures its output, and prints [OK] or [FAIL] with the label.
# Output is suppressed on success and shown on failure.
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

# --- tofu fmt ---

check_fmt() {
    run_check "tofu fmt -check -recursive" \
        tofu fmt -check -recursive
}

# --- tflint ---

check_tflint() {
    tflint --init &>/dev/null
    run_check "tflint --recursive" \
        tflint --recursive
}

# --- checkov ---

check_checkov() {
    run_check "checkov -d . --config-file .checkov.yaml" \
        checkov -d . --config-file .checkov.yaml
}

# --- tofu validate ---

VALIDATE_MODULES=(
    "k3s_cluster"
    "examples/modules/vpc_cloud"
    "examples/modules/idp_cognito"
    "examples/ex_basic"
    "examples/ex_idp"
)

check_validate() {
    local mod
    for mod in "${VALIDATE_MODULES[@]}"; do
        local mod_dir="${REPO_ROOT}/${mod}"
        local output
        if output=$(cd "${mod_dir}" && tofu init -backend=false 2>&1 && tofu validate 2>&1); then
            echo "[OK]   tofu validate: ${mod}"
            ((PASS++)) || true
        else
            echo "[FAIL] tofu validate: ${mod}"
            printf '%s\n' "${output}"
            ((FAIL++)) || true
        fi
    done
}

# --- main ---

cd "${REPO_ROOT}" || exit 1

echo "=== $(basename ${0}) (Starting) ==="
check_fmt
check_tflint
check_checkov
check_validate
echo "=== $(basename "${0}") (Completed: Results Below) ==="

if [[ "$FAIL" -eq 0 ]]; then
    echo "All ${PASS} checks passed."
else
    echo "${PASS} passed, ${FAIL} failed."
    exit 1
fi
