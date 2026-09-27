#!/usr/bin/env bash
# installers/node.sh — Standalone user-space Node.js & PM2 installer
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"

USER_APPS_DIR="${HOME}/apps"
USER_BIN_DIR="${HOME}/bin"
USER_TMP_DIR="${HOME}/tmp"
ensure_directory "$USER_APPS_DIR"
ensure_directory "$USER_BIN_DIR"
ensure_directory "$USER_TMP_DIR"

log_header "Checking / Installing Node.js & PM2"

# 1. Host Node check
if have_command node && have_command npm && have_command pm2; then
    log_ok "Node ($(node --version)), npm ($(npm --version)), and PM2 already available"
    exit 0
fi

# 2. Check existing user-space installation
if [ -x "$USER_APPS_DIR/node/bin/node" ]; then
    export PATH="$USER_APPS_DIR/node/bin:$PATH"
    log_ok "Found user-space Node at $USER_APPS_DIR/node/bin/node"
else
    detect_environment
    node_arch="x64"
    [ "$CYBER_ARCH" = "aarch64" ] && node_arch="arm64"
    node_ver="v20.18.0"
    node_tar="node-${node_ver}-linux-${node_arch}.tar.xz"
    node_url="https://nodejs.org/dist/${node_ver}/${node_tar}"
    dl_path="$USER_TMP_DIR/$node_tar"

    log_info "Downloading Node.js ${node_ver} (${node_arch})..."
    if download_file "$node_url" "$dl_path"; then
        tar -xJf "$dl_path" -C "$USER_TMP_DIR"
        rm -rf "$USER_APPS_DIR/node"
        mv "$USER_TMP_DIR/node-${node_ver}-linux-${node_arch}" "$USER_APPS_DIR/node"
        rm -f "$dl_path"
        export PATH="$USER_APPS_DIR/node/bin:$PATH"
        log_ok "Node.js installed to $USER_APPS_DIR/node"
    else
        log_warn "Node.js official binary download failed; attempting micromamba nodejs fallback..."
        bash "$SCRIPT_DIR/micromamba.sh" || true
        if have_command micromamba || [ -x "$USER_BIN_DIR/micromamba" ]; then
            MAMBA_BIN="$(command -v micromamba || echo "$USER_BIN_DIR/micromamba")"
            MAMBA_ROOT_PREFIX="$USER_APPS_DIR/micromamba" "$MAMBA_BIN" install -y -n "${CYBERVPS_ENV_NAME:-hosting}" -c conda-forge nodejs=20
        fi
    fi
fi

# Ensure npm packages can be run and PM2 is installed
if have_command npm; then
    npm config set prefix "${HOME}/.npm-global" 2>/dev/null || true
    export PATH="${HOME}/.npm-global/bin:$PATH"
    if ! have_command pm2; then
        log_info "Installing PM2 globally in user space..."
        npm install -g pm2 || true
    fi
fi

if have_command pm2; then
    log_ok "PM2 ready: $(pm2 --version 2>/dev/null || echo "installed")"
    exit 0
else
    log_warn "PM2 not found in PATH."
    exit 0
fi
