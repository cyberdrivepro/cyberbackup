#!/usr/bin/env bash
# installers/micromamba.sh — Standalone user-space Micromamba installer
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"

USER_BIN_DIR="${HOME}/bin"
USER_TMP_DIR="${HOME}/tmp"
ensure_directory "$USER_BIN_DIR"
ensure_directory "$USER_TMP_DIR"

log_header "Checking / Installing Micromamba"

if have_command micromamba; then
    log_ok "Micromamba already in PATH ($(command -v micromamba))"
    exit 0
fi
if [ -x "$USER_BIN_DIR/micromamba" ]; then
    export PATH="$USER_BIN_DIR:$PATH"
    log_ok "Micromamba found in $USER_BIN_DIR"
    exit 0
fi

detect_environment
if [ -z "${CYBER_MAMBA_ARCH:-}" ]; then
    log_error "Micromamba does not support architecture: $CYBER_ARCH"
    exit 1
fi

mamba_url="https://micro.mamba.pm/api/micromamba/${CYBER_MAMBA_ARCH}/latest"
dl_tar="$USER_TMP_DIR/micromamba-latest.tar.bz2"
extract_dir="$USER_TMP_DIR/micromamba-extract-$$"

log_info "Downloading Micromamba for ${CYBER_MAMBA_ARCH}..."
if ! download_file "$mamba_url" "$dl_tar"; then
    log_error "Failed to download Micromamba"
    exit 1
fi

mkdir -p "$extract_dir"
tar -xjf "$dl_tar" -C "$extract_dir" bin/micromamba 2>/dev/null || tar -xjf "$dl_tar" -C "$extract_dir"
if [ -f "$extract_dir/bin/micromamba" ]; then
    mv "$extract_dir/bin/micromamba" "$USER_BIN_DIR/micromamba"
elif [ -f "$extract_dir/micromamba" ]; then
    mv "$extract_dir/micromamba" "$USER_BIN_DIR/micromamba"
else
    log_error "Could not find micromamba binary in archive"
    rm -rf "$extract_dir" "$dl_tar"
    exit 1
fi

chmod +x "$USER_BIN_DIR/micromamba"
rm -rf "$extract_dir" "$dl_tar"

export PATH="$USER_BIN_DIR:$PATH"
log_ok "Micromamba successfully installed to $USER_BIN_DIR/micromamba"
exit 0
