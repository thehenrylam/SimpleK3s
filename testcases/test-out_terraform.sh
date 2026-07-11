#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: test-out_terraform.sh [options] [log_filename] [log_timestamp]

Runs fmt, tflint, checkov, and validate across all root modules.

Tool selection (default: OpenTofu / tofu):
  --use-opentofu [PATH]   use OpenTofu; PATH optionally points at the tofu binary
  --use-terraform [PATH]  use Terraform; PATH optionally points at the terraform binary

Other options:
  -h, --help              show this help and exit

Positional arguments (mainly for /test-out; sensible defaults otherwise):
  log_filename            log filename stem (default: test-out_terraform)
  log_timestamp           log timestamp     (default: now, %Y%m%d-%H%M%S)

Examples:
  test-out_terraform.sh                         # OpenTofu (tofu) on PATH
  test-out_terraform.sh --use-terraform         # Terraform (terraform) on PATH
  test-out_terraform.sh --use-terraform /opt/homebrew/bin/terraform
EOF
}

# --- Tool selection + positional args ---
# Default to OpenTofu (tofu). --use-opentofu / --use-terraform pick the binary and
# each take an OPTIONAL path to a custom binary. Anything left over is treated as
# the positional log filename + timestamp, kept for /test-out compatibility. Use
# `--` to force the rest to be positional (e.g. `--use-terraform -- mylog ts`).
TF_BIN="tofu"
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --use-opentofu)
            TF_BIN="tofu"
            if [[ -n "${2:-}" && "$2" != -* ]]; then TF_BIN="$2"; shift; fi
            shift ;;
        --use-terraform)
            TF_BIN="terraform"
            if [[ -n "${2:-}" && "$2" != -* ]]; then TF_BIN="$2"; shift; fi
            shift ;;
        -h | --help)
            usage
            exit 0 ;;
        --)
            shift
            while [[ $# -gt 0 ]]; do POSITIONAL+=("$1"); shift; done ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2 ;;
        *)
            POSITIONAL+=("$1"); shift ;;
    esac
done
set -- ${POSITIONAL[@]+"${POSITIONAL[@]}"}

if ! command -v "$TF_BIN" >/dev/null 2>&1; then
    echo "Selected binary '${TF_BIN}' not found on PATH" >&2
    exit 1
fi

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

# --- fmt ---

check_fmt() {
    run_check "${TF_BIN} fmt -check -recursive" \
        "$TF_BIN" fmt -check -recursive
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

# --- validate ---

VALIDATE_MODULES=(
    "k3s_cluster"
    "examples/modules/vpc_cloud"
    "examples/modules/idp_cognito"
    "examples/ex_basic"
    "examples/ex_idp"
    "examples/ex_tailscale"
)

check_validate() {
    local mod
    for mod in "${VALIDATE_MODULES[@]}"; do
        local mod_dir="${REPO_ROOT}/${mod}"
        local output
        if output=$(cd "${mod_dir}" && "$TF_BIN" init -backend=false 2>&1 && "$TF_BIN" validate 2>&1); then
            echo "[OK]   ${TF_BIN} validate: ${mod}"
            ((PASS++)) || true
        else
            echo "[FAIL] ${TF_BIN} validate: ${mod}"
            printf '%s\n' "${output}"
            ((FAIL++)) || true
        fi
    done
}

# --- main ---

cd "${REPO_ROOT}" || exit 1

echo "=== $(basename "${0}") (Starting) ==="
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
