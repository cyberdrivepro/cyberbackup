#!/usr/bin/env bash
# installers/cloudflared.sh — Standalone user-space Cloudflared tunnel installer
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"

USER_BIN_DIR="${HOME}/bin"
ensure_directory "$USER_BIN_DIR"

log_header "Checking / Installing Cloudflared"

if have_command cloudflared; then
    log_ok "Cloudflared already available ($(command -v cloudflared))"
    exit 0
fi
if [ -x "$USER_BIN_DIR/cloudflared" ]; then
    export PATH="$USER_BIN_DIR:$PATH"
    log_ok "Cloudflared found in $USER_BIN_DIR"
    exit 0
fi

detect_environment
if [ -z "${CYBER_CLOUDFLARED_ARCH:-}" ]; then
    log_error "Cloudflared not supported on architecture: $CYBER_ARCH"
    exit 1
fi

cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CYBER_CLOUDFLARED_ARCH}"
dest="$USER_BIN_DIR/cloudflared"

log_info "Downloading Cloudflared (linux-${CYBER_CLOUDFLARED_ARCH})..."
if download_file "$cf_url" "$dest"; then
    chmod +x "$dest"
    export PATH="$USER_BIN_DIR:$PATH"
    log_ok "Cloudflared installed to $dest"
    exit 0
else
    log_error "Cloudflared download failed"
    exit 1
fi
