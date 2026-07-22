#!/bin/bash

set -euo pipefail

# Verifies that all local testing tools are installed and prints their versions.

readonly SHELLCHECK_VERSION="0.11.0"
readonly TFLINT_VERSION="0.62.1"
readonly CHECKOV_VERSION="3.2.530"
readonly RUFF_VERSION="0.15.17"
readonly ANSIBLE_LINT_VERSION="26.6.0"   # check-versions: update in CLAUDE.md pinned versions table
readonly BIN_DIR="/opt/homebrew/bin"

PASS=0
FAIL=0

# --- shellcheck ---

check_shellcheck() {
    local bin_name="shellcheck-${SHELLCHECK_VERSION}"
    local bin_path="${BIN_DIR}/${bin_name}"
    local symlink_path="${BIN_DIR}/shellcheck"

    if [[ -f "$bin_path" ]]; then
        echo "[OK]   ${bin_name}: $("$bin_path" --version 2>&1 | grep '^version')"
        ((PASS++)) || true
    else
        echo "[MISS] ${bin_name}: not found at ${bin_path}"
        ((FAIL++)) || true
    fi

    if [[ -L "$symlink_path" ]]; then
        local target
        target="$(readlink "$symlink_path")"
        echo "       symlink shellcheck -> ${target}"
    else
        echo "       symlink shellcheck: not set"
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
    local bin_name="checkov-${CHECKOV_VERSION}"
    local bin_path="${BIN_DIR}/${bin_name}"
    local symlink_path="${BIN_DIR}/checkov"

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
        echo "       symlink checkov -> ${target}"
    else
        echo "       symlink checkov: not set"
    fi
}

# --- ruff ---

check_ruff() {
    local bin_name="ruff-${RUFF_VERSION}"
    local bin_path="${BIN_DIR}/${bin_name}"
    local symlink_path="${BIN_DIR}/ruff"

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
        echo "       symlink ruff -> ${target}"
    else
        echo "       symlink ruff: not set"
    fi
}

# --- ansible-lint ---

check_ansible_lint() {
    local bin="${BIN_DIR}/ansible-lint"

    if [[ -x "$bin" ]]; then
        # 2>/dev/null drops ansible-lint's PATH warning; NO_COLOR keeps the
        # version line free of ANSI escapes so it's clean in logs.
        echo "[OK]   ansible-lint: $(NO_COLOR=1 "$bin" --version 2>/dev/null | head -1) (want ${ANSIBLE_LINT_VERSION})"
        ((PASS++)) || true
    else
        echo "[MISS] ansible-lint: not found at ${bin}"
        ((FAIL++)) || true
    fi
}

# --- main ---

check_shellcheck
check_tflint
check_checkov
check_ruff
check_ansible_lint

echo ""
if [[ "$FAIL" -eq 0 ]]; then
    echo "All $PASS tools present."
else
    echo "$PASS present, $FAIL missing. Run ./toolchain/tc_testing_macos_install.sh to install."
    exit 1
fi
