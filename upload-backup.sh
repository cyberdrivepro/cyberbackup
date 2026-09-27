#!/usr/bin/env bash
# upload-backup.sh — upload latest CyberBackup to remote storage
set -euo pipefail

CYBERBACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$CYBERBACKUP_DIR"

LOG="$CYBERBACKUP_DIR/logs/upload.log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'
ok()      { echo -e "${GREEN}✔${RESET} $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET} $*"; }
err()     { echo -e "${RED}✖${RESET} $*"; }
header()  { echo -e "\n${BOLD}$*${RESET}\n"; }

print_error() { err "$@"; exit 1; }

REMOTE_CONF="$CYBERBACKUP_DIR/remote.conf"
if [ -f "$REMOTE_CONF" ]; then
    # shellcheck disable=SC1091
    . "$REMOTE_CONF"
fi

CYBERBACKUP_REMOTE="${CYBERBACKUP_REMOTE:-}"
CYBERBACKUP_URL="${CYBERBACKUP_URL:-}"
CYBERBACKUP_LOCAL="${CYBERBACKUP_LOCAL:-}"

UPLOAD_DIR="$HOME/cyberbackup/downloads"
LATEST_JSON="$UPLOAD_DIR/latest.json"
SHA256SUMS="$UPLOAD_DIR/SHA256SUMS"

check_remote() {
    if [ -z "$CYBERBACKUP_REMOTE" ]; then
        err "No CYBERBACKUP_REMOTE configured"
        err "Copy remote.example.conf to remote.conf and set CYBERBACKUP_REMOTE"
        exit 1
    fi
    if ! command -v rclone >/dev/null 2>&1; then
        err "rclone not found"
        exit 1
    fi
    if ! rclone listremotes 2>/dev/null | grep -q "^${CYBERBACKUP_REMOTE%%:*}"; then
        err "rclone remote '$CYBERBACKUP_REMOTE' not found"
        exit 1
    fi
}

find_latest_backup() {
    local candidates=(
        "$UPLOAD_DIR/cybervps-backup-"*.tar.zst
        "$UPLOAD_DIR/cybervps-backup-"*.tar.gz
        "$UPLOAD_DIR/cybervps-backup-"*.tar
        "$UPLOAD_DIR/cybervps-backup-"*.zip
    )
    for c in "${candidates[@]}"; do
        if [ -f "$c" ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

upload_file() {
    local src="$1"
    local dst="$2"
    if [ ! -f "$src" ]; then
        err "Source file not found: $src"
        return 1
    fi
    rclone copy "$src" "$dst" --progress || return 1
    ok "Uploaded $src -> $dst"
}

main() {
    header "UPLOAD BACKUP"
    echo "Host: $(hostname)"
    echo "User: $(whoami)"
    echo

    # Find latest backup
    local archive
    archive=$(find_latest_backup) || print_error "No backup archive found in $UPLOAD_DIR"

    if [ ! -f "$LATEST_JSON" ]; then
        print_error "latest.json not found"
    fi

    if [ ! -f "$SHA256SUMS" ]; then
        print_error "SHA256SUMS not found"
    fi

    check_remote

    local remote_path="$CYBERBACKUP_REMOTE/cybervps-backups"
    ok "Uploading to $remote_path..."

    upload_file "$archive" "$remote_path/"
    upload_file "$LATEST_JSON" "$remote_path/"
    upload_file "$SHA256SUMS" "$remote_path/"

    # Verify remote existence
    if rclone ls "$CYBERBACKUP_REMOTE" >/dev/null 2>&1; then
        ok "Remote $CYBERBACKUP_REMOTE is accessible"
    else
        err "Remote $CYBERBACKUP_REMOTE is not accessible"
        exit 1
    fi

    header "UPLOAD COMPLETE"
    ok "Backup uploaded: $archive"
    ok "latest.json uploaded"
    ok "SHA256SUMS uploaded"
}

main "$@"
