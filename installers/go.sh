#!/usr/bin/env bash
# installers/go.sh — Standalone user-space Go toolchain installer
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

log_header "Checking / Installing Go Toolchain"

if have_command go; then
    log_ok "Go already available ($(go version 2>&1))"
    exit 0
fi

if [ -x "$USER_APPS_DIR/go/bin/go" ]; then
    export PATH="$USER_APPS_DIR/go/bin:$PATH"
    log_ok "Found user-space Go at $USER_APPS_DIR/go/bin/go"
    exit 0
fi

detect_environment
go_arch="amd64"
[ "$CYBER_ARCH" = "aarch64" ] && go_arch="arm64"
go_ver="1.23.2"
go_tar="go${go_ver}.linux-${go_arch}.tar.gz"
go_url="https://go.dev/dl/${go_tar}"
dl_path="$USER_TMP_DIR/$go_tar"

log_info "Downloading Go ${go_ver} (${go_arch})..."
if download_file "$go_url" "$dl_path"; then
    rm -rf "$USER_APPS_DIR/go"
    tar -xzf "$dl_path" -C "$USER_APPS_DIR"
    rm -f "$dl_path"
    export PATH="$USER_APPS_DIR/go/bin:$PATH"
    log_ok "Go toolchain installed to $USER_APPS_DIR/go"
    exit 0
else
    log_error "Go download failed"
    exit 1
fi
