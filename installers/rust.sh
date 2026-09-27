#!/usr/bin/env bash
# installers/rust.sh — Standalone user-space Rust / Cargo installer
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

log_header "Checking / Installing Rust & Cargo"

if have_command rustc && have_command cargo; then
    log_ok "Rust ($(rustc --version 2>&1)) already available"
    exit 0
fi

if [ -x "${HOME}/.cargo/bin/rustc" ]; then
    export PATH="${HOME}/.cargo/bin:$PATH"
    log_ok "Found Rust in ~/.cargo/bin"
    exit 0
fi

log_info "Installing Rust via official rustup script (non-interactive, minimal profile)..."
rustup_sh="$USER_TMP_DIR/rustup-init.sh"
if download_file "https://sh.rustup.rs" "$rustup_sh"; then
    chmod +x "$rustup_sh"
    sh "$rustup_sh" -y --default-toolchain stable --profile minimal --no-modify-path
    rm -f "$rustup_sh"
    export PATH="${HOME}/.cargo/bin:$PATH"
    log_ok "Rust installed successfully: $(rustc --version 2>/dev/null || echo 'stable')"
    exit 0
else
    log_error "Failed to download rustup-init.sh"
    exit 1
fi
