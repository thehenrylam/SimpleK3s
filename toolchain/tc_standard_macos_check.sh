#!/bin/bash

set -euo pipefail

# Verifies that the standard SimpleK3s toolchain is installed and prints versions.

readonly UV_VERSION="0.11.20"            # check-versions: update in CLAUDE.md pinned versions table
readonly PYTHON_VERSION="3.13"           # check-versions: update in CLAUDE.md pinned versions table
readonly TOFU_VERSION="1.11.2"           # check-versions: update in CLAUDE.md pinned versions table
readonly TERRAFORM_VERSION="1.14.3"      # check-versions: update in CLAUDE.md pinned versions table
readonly AWSCLI_VERSION="2.34.63"        # check-versions: update in CLAUDE.md pinned versions table
readonly ANSIBLE_VERSION="14.2.0"        # check-versions: update in CLAUDE.md pinned versions table
readonly BIN_DIR="/opt/homebrew/bin"

PASS=0
FAIL=0

pass() { echo "[OK]   $1"; ((PASS++)) || true; }
miss() { echo "[MISS] $1"; ((FAIL++)) || true; }

# --- uv ---

check_uv() {
    local uv_bin="${BIN_DIR}/uv"
    if [[ -x "$uv_bin" ]]; then
        pass "uv: $("$uv_bin" --version) (want ${UV_VERSION})"
    else
        miss "uv: not found at ${uv_bin}"
    fi
}

# --- python (via uv) ---

check_python() {
    local uv_bin="${BIN_DIR}/uv"
    if [[ -x "$uv_bin" ]] && "$uv_bin" python find "${PYTHON_VERSION}" &>/dev/null; then
        pass "python ${PYTHON_VERSION}: $("$uv_bin" python find "${PYTHON_VERSION}")"
    else
        miss "python ${PYTHON_VERSION}: not installed via uv"
    fi
}

# --- Ansible (via uv tool) ---

check_ansible() {
    local ansible_bin="${BIN_DIR}/ansible"
    local community_bin="${BIN_DIR}/ansible-community"
    # Require both the primary CLI ('ansible') and the bundle script
    # ('ansible-community'): a stale Homebrew ansible would provide the former
    # but not the latter, and ANSIBLE_VERSION is the community bundle version.
    if [[ -x "$ansible_bin" && -x "$community_bin" ]]; then
        pass "ansible: $("$community_bin" --version 2>/dev/null | head -1) (want ${ANSIBLE_VERSION})"
    else
        miss "ansible: not found at ${ansible_bin} / ${community_bin}"
    fi
}

# --- OpenTofu ---

check_tofu() {
    local bin_name="tofu-${TOFU_VERSION}"
    local bin_path="${BIN_DIR}/${bin_name}"
    local symlink_path="${BIN_DIR}/tofu"

    if [[ -f "$bin_path" ]]; then
        pass "${bin_name}: $("$bin_path" version 2>&1 | head -1)"
    else
        miss "${bin_name}: not found at ${bin_path}"
    fi

    if [[ -L "$symlink_path" ]]; then
        echo "       symlink tofu -> $(readlink "$symlink_path")"
    else
        echo "       symlink tofu: not set"
    fi
}

# --- Terraform ---

check_terraform() {
    local bin_name="terraform-${TERRAFORM_VERSION}"
    local bin_path="${BIN_DIR}/${bin_name}"
    local symlink_path="${BIN_DIR}/terraform"

    if [[ -f "$bin_path" ]]; then
        pass "${bin_name}: $("$bin_path" version 2>&1 | head -1)"
    else
        miss "${bin_name}: not found at ${bin_path}"
    fi

    if [[ -L "$symlink_path" ]]; then
        echo "       symlink terraform -> $(readlink "$symlink_path")"
    else
        echo "       symlink terraform: not set"
    fi
}

# --- AWS CLI ---

check_awscli() {
    local aws_bin="/usr/local/bin/aws"
    if [[ -x "$aws_bin" ]]; then
        pass "aws: $("$aws_bin" --version 2>&1) (want ${AWSCLI_VERSION})"
    else
        miss "aws: not found at ${aws_bin}"
    fi
}

# --- main ---

check_uv
check_python
check_ansible
check_tofu
check_terraform
check_awscli

echo ""
if [[ "$FAIL" -eq 0 ]]; then
    echo "All $PASS tools present."
else
    echo "$PASS present, $FAIL missing. Run ./toolchain/tc_standard_macos_install.sh to install."
    exit 1
fi
