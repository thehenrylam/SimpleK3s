#!/bin/bash

set -euo pipefail

# Verifies that all local testing tools are installed and prints their versions.

TFLINT_VERSION="0.62.1"
BIN_DIR="/opt/homebrew/bin"

PASS=0
FAIL=0

# --- shellcheck ---

check_shellcheck() {
    if command -v shellcheck &>/dev/null; then
        echo "[OK]   shellcheck: $(shellcheck --version 2>&1 | head -1)"
        ((PASS++)) || true
    else
        echo "[MISS] shellcheck: not found"
        ((FAIL++)) || true
    fi
}

# --- tflint ---

check_tflint() {
    local bin_name="tflint-${TFLINT_VERSION}"
    local bin_path="${BIN_DIR}/${bin_name}"
    local symlink_path="${BIN_DIR}/tflint"

    if [[ -f "$bin_path" ]]; then
        echo "[OK]   ${bin_name}: $("$bin_path" --version 2>&1 | head -1)"
        ((PASS++)) || true
    else
        echo "[MISS] ${bin_name}: not found at ${bin_path}"
        ((FAIL++)) || true
    fi

    if [[ -L "$symlink_path" ]]; then
        local target
        target="$(readlink "$symlink_path")"
        echo "       symlink tflint -> ${target}"
    else
        echo "       symlink tflint: not set"
    fi
}

# --- checkov ---

check_checkov() {
    if command -v checkov &>/dev/null; then
        echo "[OK]   checkov: $(checkov --version 2>&1 | head -1)"
        ((PASS++)) || true
    else
        echo "[MISS] checkov: not found"
        ((FAIL++)) || true
    fi
}

# --- main ---

check_shellcheck
check_tflint
check_checkov

echo ""
if [[ "$FAIL" -eq 0 ]]; then
    echo "All $PASS tools present."
else
    echo "$PASS present, $FAIL missing. Run ./toolchain/tc_testing_macos_install.sh to install."
    exit 1
fi
