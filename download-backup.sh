#!/usr/bin/env bash
# download-backup.sh — Download CyberVPS backup from remote storage or HTTPS URL
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/remote.sh
source "$SCRIPT_DIR/lib/remote.sh"

TARGET_FILE="${1:-latest}"
DEST_DIR="${2:-$SCRIPT_DIR/downloads}"

acquire_lock "download" || exit 1
trap 'release_lock' EXIT

download_snapshot "$TARGET_FILE" "$DEST_DIR"
exit 0
