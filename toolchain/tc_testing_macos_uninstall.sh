#!/bin/bash

set -euo pipefail

# Removes local testing tools installed by tc_testing_macos_install.sh.

readonly SHELLCHECK_VERSION="0.11.0"
readonly TFLINT_VERSION="0.62.1"
readonly CHECKOV_VERSION="3.2.530"
readonly RUFF_VERSION="0.15.17"
readonly BIN_DIR="/opt/homebrew/bin"

# --- shellcheck ---

uninstall_shellcheck() {
    echo "==> Uninstalling shellcheck"

    local bin_name="shellcheck-${SHELLCHECK_VERSION}"
    local bin_path="${BIN_DIR}/${bin_name}"
    local symlink_path="${BIN_DIR}/shellcheck"

    if [[ -L "$symlink_path" ]]; then
        local current_target
        current_target="$(readlink "$symlink_path")"
        if [[ "$current_target" == "$bin_path" ]]; then
            rm "$symlink_path"
            echo "  Removed symlink: shellcheck -> ${bin_name}"
        else
            echo "  Symlink 'shellcheck' points elsewhere (${current_target}) — leaving it."
        fi
    fi

    if [[ -f "$bin_path" ]]; then
        rm "$bin_path"
        echo "  Removed: ${bin_path}"
    else
        echo "  Not installed: ${bin_path}"
    fi
}

# --- tflint ---

uninstall_tflint() {
    echo "==> Uninstalling tflint"

    local bin_name="tflint-${TFLINT_VERSION}"
    local bin_path="${BIN_DIR}/${bin_name}"
    local symlink_path="${BIN_DIR}/tflint"

    if [[ -L "$symlink_path" ]]; then
        local current_target
        current_target="$(readlink "$symlink_path")"
        if [[ "$current_target" == "$bin_path" ]]; then
            rm "$symlink_path"
            echo "  Removed symlink: tflint -> ${bin_name}"
        else
            echo "  Symlink 'tflint' points elsewhere (${current_target}) — leaving it."
        fi
    fi

    if [[ -f "$bin_path" ]]; then
        rm "$bin_path"
        echo "  Removed: ${bin_path}"
    else
        echo "  Not installed: ${bin_path}"
    fi
}

# --- checkov ---

uninstall_checkov() {
    echo "==> Uninstalling checkov"

    local bin_name="checkov-${CHECKOV_VERSION}"
    local bin_path="${BIN_DIR}/${bin_name}"
    local symlink_path="${BIN_DIR}/checkov"

    if [[ -L "$symlink_path" ]]; then
        local current_target
        current_target="$(readlink "$symlink_path")"
        if [[ "$current_target" == "$bin_path" ]]; then
            rm "$symlink_path"
            echo "  Removed symlink: checkov -> ${bin_name}"
        else
            echo "  Symlink 'checkov' points elsewhere (${current_target}) — leaving it."
        fi
    fi

    if [[ -f "$bin_path" ]]; then
        rm "$bin_path"
        echo "  Removed: ${bin_path}"
    else
        echo "  Not installed: ${bin_path}"
    fi

    pip3 uninstall -y checkov || true
}

# --- ruff ---

uninstall_ruff() {
    echo "==> Uninstalling ruff"

    local bin_name="ruff-${RUFF_VERSION}"
    local bin_path="${BIN_DIR}/${bin_name}"
    local symlink_path="${BIN_DIR}/ruff"

    if [[ -L "$symlink_path" ]]; then
        local current_target
        current_target="$(readlink "$symlink_path")"
        if [[ "$current_target" == "$bin_path" ]]; then
            rm "$symlink_path"
            echo "  Removed symlink: ruff -> ${bin_name}"
        else
            echo "  Symlink 'ruff' points elsewhere (${current_target}) — leaving it."
        fi
    fi

    if [[ -f "$bin_path" ]]; then
        rm "$bin_path"
        echo "  Removed: ${bin_path}"
    else
        echo "  Not installed: ${bin_path}"
    fi
}

# --- main ---

uninstall_shellcheck
uninstall_tflint
uninstall_checkov
uninstall_ruff

echo ""
echo "Done."
