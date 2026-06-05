#!/bin/bash

set -euo pipefail

# Installs local testing tools for contributors on macOS.
# Requires Homebrew. Does NOT install OpenTofu (see tc_tofu_*.sh).

TFLINT_VERSION="0.62.1"
BIN_DIR="/opt/homebrew/bin"

# --- shellcheck ---

install_shellcheck() {
    echo "==> Installing shellcheck"
    brew install shellcheck
}

# --- tflint ---

install_tflint() {
    echo "==> Installing tflint"

    local bin_name="tflint-${TFLINT_VERSION}"
    local bin_path="${BIN_DIR}/${bin_name}"
    local symlink_path="${BIN_DIR}/tflint"

    local arch
    case "$(uname -m)" in
        arm64)  arch="arm64" ;;
        x86_64) arch="amd64" ;;
        *) echo "ERROR: Unsupported architecture: $(uname -m)" >&2; return 1 ;;
    esac

    mkdir -p "$BIN_DIR"

    local url="https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_darwin_${arch}.zip"
    local tmpdir
    tmpdir="$(mktemp -d)"

    echo "  Downloading tflint v${TFLINT_VERSION} (${arch})..."
    curl -fsSL "$url" -o "${tmpdir}/tflint.zip"
    unzip -q "${tmpdir}/tflint.zip" -d "$tmpdir"
    install -m 755 "${tmpdir}/tflint" "$bin_path"
    rm -rf "$tmpdir"

    echo "  Installed: ${bin_path}"

    if [[ -L "$symlink_path" ]]; then
        local current_target
        current_target="$(readlink "$symlink_path")"
        echo "  Symlink 'tflint' already exists -> ${current_target}"
        printf "  Point 'tflint' to %s instead? [y/N] " "$bin_name"
        read -r answer
        if [[ "${answer,,}" == "y" ]]; then
            ln -sf "$bin_path" "$symlink_path"
            echo "  Updated symlink: tflint -> ${bin_name}"
        else
            echo "  Keeping existing symlink."
        fi
    elif [[ -e "$symlink_path" ]]; then
        echo "  WARNING: ${symlink_path} exists but is not a symlink — skipping symlink creation."
    else
        ln -s "$bin_path" "$symlink_path"
        echo "  Created symlink: tflint -> ${bin_name}"
    fi
}

# --- checkov ---

install_checkov() {
    echo "==> Installing checkov"
    brew install checkov
}

# --- main ---

if ! command -v brew &>/dev/null; then
    echo "ERROR: Homebrew is not installed. Install it from https://brew.sh and re-run." >&2
    exit 1
fi

install_shellcheck
install_tflint
install_checkov

echo ""
echo "All tools installed. Run ./toolchain/tc_testing_macos_check.sh to verify."
