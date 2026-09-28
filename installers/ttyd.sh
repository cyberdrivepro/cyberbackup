#!/usr/bin/env bash
# installers/ttyd.sh — Rootless standalone ttyd installer for CyberVPS
set -euo pipefail

INSTALL_DIR="${HOME}/.local/bin"
mkdir -p "$INSTALL_DIR"

if command -v ttyd >/dev/null 2>&1; then
    echo "ttyd is already installed: $(command -v ttyd)"
    ttyd --version 2>/dev/null || true
    exit 0
fi

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64) BIN_URL="https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64" ;;
    aarch64|arm64) BIN_URL="https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.aarch64" ;;
    armv7l) BIN_URL="https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.armhf" ;;
    *) echo "Unsupported architecture for prebuilt ttyd: $ARCH"; exit 1 ;;
esac

echo "Downloading standalone ttyd ($ARCH) from GitHub releases..."
curl -fsSL "$BIN_URL" -o "$INSTALL_DIR/ttyd"
chmod +x "$INSTALL_DIR/ttyd"
echo "ttyd installed successfully in $INSTALL_DIR/ttyd"
"$INSTALL_DIR/ttyd" --version
exit 0
