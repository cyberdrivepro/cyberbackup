#!/usr/bin/env bash
# upload-backup.sh — Upload latest or specified CyberVPS backup to remote storage
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/restore.sh
source "$SCRIPT_DIR/lib/restore.sh"
# shellcheck source=lib/remote.sh
source "$SCRIPT_DIR/lib/remote.sh"

ARCHIVE_PATH="${1:-}"

if [ -z "$ARCHIVE_PATH" ]; then
    ARCHIVE_PATH="$(find_backup_archive "$SCRIPT_DIR/downloads" 2>/dev/null || true)"
fi

if [ -z "$ARCHIVE_PATH" ] || [ ! -f "$ARCHIVE_PATH" ]; then
    log_error "No backup archive found in $SCRIPT_DIR/downloads to upload."
    exit 1
fi

acquire_lock "upload" || exit 1
trap 'release_lock' EXIT

upload_snapshot "$ARCHIVE_PATH"
exit 0
