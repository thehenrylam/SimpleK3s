#!/bin/bash

set -euo pipefail

# Removes the standard SimpleK3s toolchain installed by tc_standard_macos_install.sh.

# shellcheck disable=SC2155
readonly CURR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2155
readonly REPO_ROOT="$(cd "${CURR_ROOT}/.." && pwd)"

readonly PYTHON_VERSION="3.13"           # check-versions: update in CLAUDE.md pinned versions table
readonly TOFU_VERSION="1.11.2"           # check-versions: update in CLAUDE.md pinned versions table
readonly TERRAFORM_VERSION="1.14.3"      # check-versions: update in CLAUDE.md pinned versions table
readonly BIN_DIR="/opt/homebrew/bin"

readonly PY_DIR="${REPO_ROOT}/k3s_cluster/cluster_app/bootstrap/data/py"

# --- helpers ---

# Remove a versioned binary and its symlink (only if the symlink still
# points at the version we installed). Mirrors tc_testing_macos_uninstall.sh.
remove_symlinked_binary() {
    local tool="$1"
    local bin_name="$2"
    local bin_path="${BIN_DIR}/${bin_name}"
    local symlink_path="${BIN_DIR}/${tool}"

    if [[ -L "$symlink_path" ]]; then
        local current_target
        current_target="$(readlink "$symlink_path")"
        if [[ "$current_target" == "$bin_path" ]]; then
            rm "$symlink_path"
            echo "  Removed symlink: ${tool} -> ${bin_name}"
        else
            echo "  Symlink '${tool}' points elsewhere (${current_target}) — leaving it."
        fi
    fi

    if [[ -f "$bin_path" ]]; then
        rm "$bin_path"
        echo "  Removed: ${bin_path}"
    else
        echo "  Not installed: ${bin_path}"
    fi
}

# --- Ansible (via uv tool) ---

uninstall_ansible() {
    echo "==> Removing Ansible"

    # Removed via uv so the isolated tool venv and its BIN_DIR entry points go
    # together. Must run before uv itself is removed.
    if [[ -x "${BIN_DIR}/uv" ]]; then
        UV_TOOL_BIN_DIR="${BIN_DIR}" "${BIN_DIR}/uv" tool uninstall ansible || \
            echo "  Ansible was not installed via uv — skipping."
    else
        echo "  uv not found — skipping Ansible removal."
    fi
}

# --- bootstrap python deps (legacy) ---

# The bootstrap py/ tree no longer has a project virtualenv — it is stdlib-only
# and runs on the system python3. This step remains solely to clean up the ~50 MB
# .venv left behind on machines that installed the toolchain before that change;
# nothing recreates it. Safe to delete once no contributor is on the old layout.
uninstall_python_deps() {
    echo "==> Removing bootstrap Python deps (legacy .venv)"

    if [[ -d "${PY_DIR}/.venv" ]]; then
        rm -rf "${PY_DIR}/.venv"
        echo "  Removed: ${PY_DIR}/.venv"
    else
        echo "  Not present: ${PY_DIR}/.venv"
    fi
}

# --- python (via uv) ---

uninstall_python() {
    echo "==> Removing Python ${PYTHON_VERSION} (via uv)"

    if [[ -x "${BIN_DIR}/uv" ]]; then
        "${BIN_DIR}/uv" python uninstall "${PYTHON_VERSION}" || \
            echo "  Python ${PYTHON_VERSION} was not managed by uv — skipping."
    else
        echo "  uv not found — skipping Python removal."
    fi
}

# --- uv ---

uninstall_uv() {
    echo "==> Removing uv"

    if [[ -x "${BIN_DIR}/uv" ]]; then
        "${BIN_DIR}/uv" cache clean || true
    fi

    local removed=0
    for f in uv uvx; do
        if [[ -f "${BIN_DIR}/${f}" ]]; then
            rm "${BIN_DIR}/${f}"
            echo "  Removed: ${BIN_DIR}/${f}"
            removed=1
        fi
    done
    # Use a full if-block, not `[[ ... ]] && echo`: when uv *was* removed the
    # test is false, making it the function's last (failing) statement, which
    # under `set -e` aborts the whole uninstall before tofu/terraform/aws run.
    if [[ "$removed" -eq 0 ]]; then
        echo "  Not installed: ${BIN_DIR}/uv"
    fi
}

# --- OpenTofu ---

uninstall_tofu() {
    echo "==> Removing OpenTofu"
    remove_symlinked_binary "tofu" "tofu-${TOFU_VERSION}"
}

# --- Terraform ---

uninstall_terraform() {
    echo "==> Removing Terraform"
    remove_symlinked_binary "terraform" "terraform-${TERRAFORM_VERSION}"
}

# --- AWS CLI ---

uninstall_awscli() {
    echo "==> Removing AWS CLI"

    # Reverses the .pkg install per AWS docs: drop the install dir and symlinks.
    # Needs sudo because everything lives under /usr/local.
    if [[ -d /usr/local/aws-cli ]]; then
        echo "  Removing /usr/local/aws-cli and symlinks (sudo may prompt)..."
        sudo rm -rf /usr/local/aws-cli
        sudo rm -f /usr/local/bin/aws /usr/local/bin/aws_completer
        echo "  Removed AWS CLI."
    else
        echo "  Not installed: /usr/local/aws-cli"
    fi
}

# --- main ---

uninstall_ansible
uninstall_python_deps
uninstall_python
uninstall_uv
uninstall_tofu
uninstall_terraform
uninstall_awscli

echo ""
echo "Done."
