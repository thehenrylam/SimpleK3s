#!/bin/bash

set -euo pipefail

# Installs the standard toolchain needed to work on SimpleK3s on macOS.
# Installs: uv, Python (via uv), Ansible, OpenTofu, Terraform, and the AWS CLI.
# Requires Homebrew.
# For local *testing* tools (shellcheck, tflint, checkov) see tc_testing_*.sh.

readonly UV_VERSION="0.11.20"            # check-versions: update in CLAUDE.md pinned versions table
readonly PYTHON_VERSION="3.13"           # check-versions: update in CLAUDE.md pinned versions table
readonly TOFU_VERSION="1.11.2"           # check-versions: update in CLAUDE.md pinned versions table
readonly TERRAFORM_VERSION="1.14.3"      # check-versions: update in CLAUDE.md pinned versions table
readonly AWSCLI_VERSION="2.34.63"        # check-versions: update in CLAUDE.md pinned versions table
readonly ANSIBLE_VERSION="14.2.0"        # check-versions: update in CLAUDE.md pinned versions table
readonly BIN_DIR="/opt/homebrew/bin"

# NOTE: there is deliberately no bootstrap Python project to sync. Everything
# under k3s_cluster/cluster_app/bootstrap/data/py/ is stdlib-only and runs on the
# system python3, so there is no pyproject.toml and no .venv. Scripts needing a
# third-party package declare it inline (PEP 723) and run via `uv run`.

# --- helpers ---

# Maintain a versioned binary plus a stable symlink, prompting before
# repointing an existing symlink. Mirrors tc_testing_macos_install.sh.
manage_symlink() {
    local tool="$1"
    local bin_name="$2"
    local bin_path="$3"
    local symlink_path="${BIN_DIR}/${tool}"

    if [[ -L "$symlink_path" ]]; then
        local current_target
        current_target="$(readlink "$symlink_path")"
        echo "  Symlink '${tool}' already exists -> ${current_target}"
        printf "  Point '%s' to %s instead? [y/N] " "$tool" "$bin_name"
        read -r answer
        if [[ "$answer" == "y" ]] || [[ "$answer" == "Y" ]]; then
            ln -sf "$bin_path" "$symlink_path"
            echo "  Updated symlink: ${tool} -> ${bin_name}"
        else
            echo "  Keeping existing symlink."
        fi
    elif [[ -e "$symlink_path" ]]; then
        echo "  WARNING: ${symlink_path} exists but is not a symlink — skipping symlink creation."
    else
        ln -s "$bin_path" "$symlink_path"
        echo "  Created symlink: ${tool} -> ${bin_name}"
    fi
}

# Detect arch in the naming flavor used by a given project.
# Usage: detect_arch <arm64_name> <x86_64_name>
detect_arch() {
    case "$(uname -m)" in
        arm64)  echo "$1" ;;
        x86_64) echo "$2" ;;
        *) echo "ERROR: Unsupported architecture: $(uname -m)" >&2; return 1 ;;
    esac
}

# --- uv ---

install_uv() {
    echo "==> Installing uv"

    mkdir -p "$BIN_DIR"

    echo "  Installing uv v${UV_VERSION} via the official installer..."
    # UV_INSTALL_DIR places uv/uvx straight into BIN_DIR (already on PATH);
    # UV_NO_MODIFY_PATH keeps the installer from editing shell profiles.
    curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" \
        | env UV_INSTALL_DIR="${BIN_DIR}" UV_NO_MODIFY_PATH=1 sh

    echo "  Installed: $("${BIN_DIR}/uv" --version)"
}

# --- python (via uv) ---

install_python() {
    echo "==> Installing Python ${PYTHON_VERSION} (via uv)"

    "${BIN_DIR}/uv" python install "${PYTHON_VERSION}"

    echo "  Installed: $("${BIN_DIR}/uv" python find "${PYTHON_VERSION}")"
}

# --- Ansible (via uv tool) ---

install_ansible() {
    echo "==> Installing Ansible ${ANSIBLE_VERSION} (via uv tool)"

    # Ansible is a multi-command Python suite (ansible, ansible-playbook,
    # ansible-galaxy, ...), so the versioned-binary + symlink pattern used for
    # single static binaries doesn't fit. Instead uv owns an isolated, pinned
    # tool venv; UV_TOOL_BIN_DIR drops its entry points into BIN_DIR (already on
    # PATH), and --force repoints an existing install to the pinned version
    # (including over a pre-existing Homebrew ansible in the same bin dir).
    #
    # The 'ansible' PyPI package (the community bundle) only exposes an
    # 'ansible-community' console script; the actual CLIs (ansible,
    # ansible-playbook, ...) belong to its ansible-core dependency, so
    # --with-executables-from links those too — without it the install is
    # unusable.
    UV_TOOL_BIN_DIR="${BIN_DIR}" "${BIN_DIR}/uv" tool install --force \
        --with-executables-from ansible-core "ansible==${ANSIBLE_VERSION}"

    # ANSIBLE_VERSION is the community bundle version, reported by
    # 'ansible-community'; 'ansible' itself reports the bundled ansible-core.
    echo "  Installed: $("${BIN_DIR}/ansible-community" --version 2>/dev/null | head -1)"
    echo "             $("${BIN_DIR}/ansible" --version | head -1)"
}

# --- OpenTofu ---

install_tofu() {
    echo "==> Installing OpenTofu"

    local bin_name="tofu-${TOFU_VERSION}"
    local bin_path="${BIN_DIR}/${bin_name}"

    local arch
    arch="$(detect_arch arm64 amd64)" || return 1

    mkdir -p "$BIN_DIR"

    local url="https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_darwin_${arch}.zip"
    local tmpdir
    tmpdir="$(mktemp -d)"

    echo "  Downloading OpenTofu v${TOFU_VERSION} (${arch})..."
    curl -fsSL "$url" -o "${tmpdir}/tofu.zip"
    unzip -q "${tmpdir}/tofu.zip" -d "$tmpdir"
    install -m 755 "${tmpdir}/tofu" "$bin_path"
    rm -rf "$tmpdir"

    echo "  Installed: ${bin_path}"
    manage_symlink "tofu" "$bin_name" "$bin_path"
}

# --- Terraform ---

install_terraform() {
    echo "==> Installing Terraform"

    local bin_name="terraform-${TERRAFORM_VERSION}"
    local bin_path="${BIN_DIR}/${bin_name}"

    local arch
    arch="$(detect_arch arm64 amd64)" || return 1

    mkdir -p "$BIN_DIR"

    local url="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_darwin_${arch}.zip"
    local tmpdir
    tmpdir="$(mktemp -d)"

    echo "  Downloading Terraform v${TERRAFORM_VERSION} (${arch})..."
    curl -fsSL "$url" -o "${tmpdir}/terraform.zip"
    unzip -q "${tmpdir}/terraform.zip" -d "$tmpdir"
    install -m 755 "${tmpdir}/terraform" "$bin_path"
    rm -rf "$tmpdir"

    echo "  Installed: ${bin_path}"
    manage_symlink "terraform" "$bin_name" "$bin_path"
}

# --- AWS CLI ---

install_awscli() {
    echo "==> Installing AWS CLI"

    # AWS CLI v2 on macOS ships only as a .pkg installer, which writes to
    # /usr/local and therefore needs sudo. This is the official, version-pinned
    # install method (https://awscli.amazonaws.com/AWSCLIV2-<version>.pkg).
    local url="https://awscli.amazonaws.com/AWSCLIV2-${AWSCLI_VERSION}.pkg"
    local tmpdir
    tmpdir="$(mktemp -d)"

    echo "  Downloading AWS CLI v${AWSCLI_VERSION}..."
    curl -fsSL "$url" -o "${tmpdir}/AWSCLIV2.pkg"

    echo "  Installing via 'sudo installer' (you may be prompted for your password)..."
    sudo installer -pkg "${tmpdir}/AWSCLIV2.pkg" -target /
    rm -rf "$tmpdir"

    echo "  Installed: $(/usr/local/bin/aws --version)"
    if [[ "$(command -v aws)" != "/usr/local/bin/aws" ]]; then
        echo "  NOTE: 'aws' on your PATH resolves to $(command -v aws), not the"
        echo "        pinned /usr/local/bin/aws. Adjust your PATH if you need v${AWSCLI_VERSION}."
    fi
}

# --- main ---

if ! command -v brew &>/dev/null; then
    echo "ERROR: Homebrew is not installed. Install it from https://brew.sh and re-run." >&2
    exit 1
fi

install_uv
install_python
install_ansible
install_tofu
install_terraform
install_awscli

echo ""
echo "All tools installed. Run ./toolchain/tc_standard_macos_check.sh to verify."
