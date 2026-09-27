#!/usr/bin/env bash
# download-backup.sh — download CyberBackup from remote or URL
set -euo pipefail

CYBERBACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$CYBERBACKUP_DIR"

DOWNLOAD_DIR="$HOME/cyberbackup/downloads"
mkdir -p "$DOWNLOAD_DIR"

LOG="$CYBERBACKUP_DIR/logs/download.log"
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

download_from_remote() {
    local remote="$1"
    local path="$2"
    local dest="$3"

    if ! command -v rclone >/dev/null 2>&1; then
        err "rclone not found"
        return 1
    fi

    if ! rclone listremotes 2>/dev/null | grep -q "^${remote%%:*}"; then
        err "rclone remote '$remote' not found"
        return 1
    fi

    rclone copy "$remote:$path" "$dest" --progress || return 1
    ok "Downloaded from $remote:$path to $dest"
}

download_from_url() {
    local url="$1"
    local dest="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$dest" "$url" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$dest" "$url" || return 1
    else
        err "Neither curl nor wget available"
        return 1
    fi
    ok "Downloaded from $url to $dest"
}

download_from_local() {
    local src="$1"
    local dest_dir="$2"
    if [ ! -f "$src" ]; then
        err "Local file not found: $src"
        return 1
    fi
    cp "$src" "$dest_dir/"
    ok "Copied $src to $dest_dir"
}

find_latest_json_remote() {
    local remote="$1"
    local path="$2"
    if ! command -v rclone >/dev/null 2>&1; then
        err "rclone not found"
        return 1
    fi
    rclone cat "$remote:$path/latest.json" 2>/dev/null || return 1
}

main() {
    header "DOWNLOAD BACKUP"
    echo "Host: $(hostname)"
    echo "User: $(whoami)"
    echo

    # Determine source
    if [ -n "$CYBERBACKUP_URL" ]; then
        ok "Using HTTPS URL: $CYBERBACKUP_URL"
        download_from_url "$CYBERBACKUP_URL" "$DOWNLOAD_DIR/" || print_error "Download from URL failed"
        # Also download SHA256SUMS if URL points to a directory listing? Not trivial.
        # For simplicity, assume user provides URL to a metadata endpoint or passes SHA256 separately.
        warn "SHA256 verification requires SHA256SUMS; download it separately if needed"
        exit 0
    fi

    if [ -n "$CYBERBACKUP_LOCAL" ]; then
        ok "Using local path: $CYBERBACKUP_LOCAL"
        download_from_local "$CYBERBACKUP_LOCAL" "$DOWNLOAD_DIR" || print_error "Local copy failed"
        exit 0
    fi

    if [ -n "$CYBERBACKUP_REMOTE" ]; then
        ok "Using rclone remote: $CYBERBACKUP_REMOTE"
        local remote_base="${CYBERBACKUP_REMOTE}/cybervps-backups"
        # Download latest.json first
        if ! download_from_remote "$remote_base" "latest.json" "$DOWNLOAD_DIR/latest.json"; then
            err "Failed to download latest.json"
            exit 1
        fi
        # Parse latest.json to get archive filename
        if command -v jq >/dev/null 2>&1; then
            local archive_name
            archive_name=$(jq -r '.archive_file // empty' "$DOWNLOAD_DIR/latest.json" 2>/dev/null || true)
            if [ -n "$archive_name" ] && [ "$archive_name" != "null" ]; then
                ok "Found archive: $archive_name"
                download_from_remote "$remote_base" "$archive_name" "$DOWNLOAD_DIR/$archive_name" || print_error "Failed to download archive"
                # Also download SHA256SUMS
                download_from_remote "$remote_base" "SHA256SUMS" "$DOWNLOAD_DIR/SHA256SUMS" || warn "SHA256SUMS not found"
            else
                warn "latest.json does not contain archive_file; listing remote..."
                rclone ls "$remote_base" 2>/dev/null || true
            fi
        else
            warn "jq not found; cannot parse latest.json"
        fi
        exit 0
    fi

    err "No download source configured"
    err "Set CYBERBACKUP_REMOTE, CYBERBACKUP_URL, or CYBERBACKUP_LOCAL in remote.conf"
    exit 1
}

main "$@"
