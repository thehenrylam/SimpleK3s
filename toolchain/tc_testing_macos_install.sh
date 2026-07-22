#!/bin/bash

set -euo pipefail

# Installs local testing tools for contributors on macOS.
# Requires Homebrew. Does NOT install OpenTofu (see tc_tofu_*.sh).

readonly SHELLCHECK_VERSION="0.11.0"
readonly TFLINT_VERSION="0.62.1"
readonly CHECKOV_VERSION="3.2.530"
readonly RUFF_VERSION="0.15.17"
readonly ANSIBLE_LINT_VERSION="26.6.0"   # check-versions: update in CLAUDE.md pinned versions table
readonly BIN_DIR="/opt/homebrew/bin"

# --- shellcheck ---

install_shellcheck() {
    echo "==> Installing shellcheck"

    local bin_name="shellcheck-${SHELLCHECK_VERSION}"
    local bin_path="${BIN_DIR}/${bin_name}"
    local symlink_path="${BIN_DIR}/shellcheck"

    local arch
    case "$(uname -m)" in
        arm64)  arch="aarch64" ;;
        x86_64) arch="x86_64" ;;
        *) echo "ERROR: Unsupported architecture: $(uname -m)" >&2; return 1 ;;
    esac

    mkdir -p "$BIN_DIR"

    local url="https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.darwin.${arch}.tar.xz"
    local tmpdir
    tmpdir="$(mktemp -d)"

    echo "  Downloading shellcheck v${SHELLCHECK_VERSION} (${arch})..."
    curl -fsSL "$url" | tar -xJ -C "$tmpdir"
    install -m 755 "${tmpdir}/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" "$bin_path"
    rm -rf "$tmpdir"

    echo "  Installed: ${bin_path}"

    if [[ -L "$symlink_path" ]]; then
        local current_target
        current_target="$(readlink "$symlink_path")"
        echo "  Symlink 'shellcheck' already exists -> ${current_target}"
        printf "  Point 'shellcheck' to %s instead? [y/N] " "$bin_name"
        read -r answer
        if [[ "$answer" == "y" ]] || [[ "$answer" == "Y" ]]; then
            ln -sf "$bin_path" "$symlink_path"
            echo "  Updated symlink: shellcheck -> ${bin_name}"
        else
            echo "  Keeping existing symlink."
        fi
    elif [[ -e "$symlink_path" ]]; then
        echo "  WARNING: ${symlink_path} exists but is not a symlink — skipping symlink creation."
    else
        ln -s "$bin_path" "$symlink_path"
        echo "  Created symlink: shellcheck -> ${bin_name}"
    fi
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
        if [[ "$answer" == "y" ]] || [[ "$answer" == "Y" ]]; then
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

    local bin_name="checkov-${CHECKOV_VERSION}"
    local bin_path="${BIN_DIR}/${bin_name}"
    local symlink_path="${BIN_DIR}/checkov"

    echo "  Installing checkov v${CHECKOV_VERSION} via pip..."
    pip3 install "checkov==${CHECKOV_VERSION}"

    local pip_bin
    pip_bin="$(python3 -m site --user-base)/bin/checkov"

    if [[ ! -f "$pip_bin" ]]; then
        echo "  ERROR: could not find checkov binary at ${pip_bin}" >&2
        return 1
    fi

    mkdir -p "$BIN_DIR"
    cp "$pip_bin" "$bin_path"
    chmod 755 "$bin_path"
    echo "  Copied to: ${bin_path}"

    if [[ -L "$symlink_path" ]]; then
        local current_target
        current_target="$(readlink "$symlink_path")"
        echo "  Symlink 'checkov' already exists -> ${current_target}"
        printf "  Point 'checkov' to %s instead? [y/N] " "$bin_name"
        read -r answer
        if [[ "$answer" == "y" ]] || [[ "$answer" == "Y" ]]; then
            ln -sf "$bin_path" "$symlink_path"
            echo "  Updated symlink: checkov -> ${bin_name}"
        else
            echo "  Keeping existing symlink."
        fi
    elif [[ -e "$symlink_path" ]]; then
        echo "  WARNING: ${symlink_path} exists but is not a symlink — skipping symlink creation."
    else
        ln -s "$bin_path" "$symlink_path"
        echo "  Created symlink: checkov -> ${bin_name}"
    fi
}

# --- ruff ---

install_ruff() {
    echo "==> Installing ruff"

    local bin_name="ruff-${RUFF_VERSION}"
    local bin_path="${BIN_DIR}/${bin_name}"
    local symlink_path="${BIN_DIR}/ruff"

    local arch
    case "$(uname -m)" in
        arm64)  arch="aarch64" ;;
        x86_64) arch="x86_64" ;;
        *) echo "ERROR: Unsupported architecture: $(uname -m)" >&2; return 1 ;;
    esac

    mkdir -p "$BIN_DIR"

    local url="https://github.com/astral-sh/ruff/releases/download/${RUFF_VERSION}/ruff-${arch}-apple-darwin.tar.gz"
    local tmpdir
    tmpdir="$(mktemp -d)"

    echo "  Downloading ruff v${RUFF_VERSION} (${arch})..."
    curl -fsSL "$url" | tar -xz -C "$tmpdir"
    install -m 755 "${tmpdir}/ruff-${arch}-apple-darwin/ruff" "$bin_path"
    rm -rf "$tmpdir"

    echo "  Installed: ${bin_path}"

    if [[ -L "$symlink_path" ]]; then
        local current_target
        current_target="$(readlink "$symlink_path")"
        echo "  Symlink 'ruff' already exists -> ${current_target}"
        printf "  Point 'ruff' to %s instead? [y/N] " "$bin_name"
        read -r answer
        if [[ "$answer" == "y" ]] || [[ "$answer" == "Y" ]]; then
            ln -sf "$bin_path" "$symlink_path"
            echo "  Updated symlink: ruff -> ${bin_name}"
        else
            echo "  Keeping existing symlink."
        fi
    elif [[ -e "$symlink_path" ]]; then
        echo "  WARNING: ${symlink_path} exists but is not a symlink — skipping symlink creation."
    else
        ln -s "$bin_path" "$symlink_path"
        echo "  Created symlink: ruff -> ${bin_name}"
    fi
}

# --- ansible-lint (via uv tool) ---

install_ansible_lint() {
    echo "==> Installing ansible-lint ${ANSIBLE_LINT_VERSION} (via uv tool)"

    # ansible-lint pulls in ansible-core, so it's installed as an isolated,
    # pinned uv tool (same rationale as Ansible in the standard toolchain);
    # UV_TOOL_BIN_DIR drops its entry point into BIN_DIR. Requires uv, which the
    # standard toolchain installs.
    if [[ ! -x "${BIN_DIR}/uv" ]]; then
        echo "  ERROR: uv not found at ${BIN_DIR}/uv." >&2
        echo "         Run ./toolchain/tc_standard_macos_install.sh first." >&2
        return 1
    fi

    UV_TOOL_BIN_DIR="${BIN_DIR}" "${BIN_DIR}/uv" tool install --force "ansible-lint==${ANSIBLE_LINT_VERSION}"

    # 2>/dev/null drops ansible-lint's PATH warning; NO_COLOR keeps the version
    # line free of ANSI escapes.
    echo "  Installed: $(NO_COLOR=1 "${BIN_DIR}/ansible-lint" --version 2>/dev/null | head -1)"
}

# --- main ---

if ! command -v brew &>/dev/null; then
    echo "ERROR: Homebrew is not installed. Install it from https://brew.sh and re-run." >&2
    exit 1
fi

install_shellcheck
install_tflint
install_checkov
install_ruff
install_ansible_lint

echo ""
echo "All tools installed. Run ./toolchain/tc_testing_macos_check.sh to verify."
