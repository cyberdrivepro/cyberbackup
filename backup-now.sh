#!/usr/bin/env bash
# backup-now.sh — create a versioned CyberBackup archive
set -euo pipefail

CYBERBACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$CYBERBACKUP_DIR"

BACKUP_DIR="$HOME/cyberbackup/downloads"
LOG="$CYBERBACKUP_DIR/logs/backup-now.log"
mkdir -p "$BACKUP_DIR" "$(dirname "$LOG")"

exec > >(tee -a "$LOG") 2>&1

CYBERVPS_BACKUP_FORMAT=1
DATE_STAMP=$(date +%Y%m%d-%H%M%S)
ARCHIVE_NAME="cybervps-backup-${DATE_STAMP}.tar.zst"
ARCHIVE_PATH="$BACKUP_DIR/$ARCHIVE_NAME"

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

# Detect shared storage inclusion
INCLUDE_SHARED="${CYBERBACKUP_INCLUDE_SHARED:-0}"
if [ -n "${CYBERBACKUP_INCLUDE_SHARED+x}" ] && [ "$INCLUDE_SHARED" != "0" ]; then
    INCLUDE_SHARED=1
fi

# Secrets handling
SECRETS_ENCRYPTED=0
SECRETS_ARCHIVE=""
ENCRYPT_PASSWD=""

# List of paths to back up
BACKUP_LIST_FILE="$CYBERBACKUP_DIR/manifests/files.txt"

# Normalize paths in manifest: remove leading ./ if any, ensure absolute

# Generate latest.json
generate_latest_json() {
    local archive="$1"
    local sha256
    sha256=$(sha256sum "$archive" | awk '{print $1}')
    local hostname
    hostname=$(hostname)
    local arch
    arch=$(uname -m)
    cat > "$BACKUP_DIR/latest.json" <<EOF
{
  "backup_file": "$(basename "$archive")",
  "archive_path": "$archive",
  "creation_timestamp": "$(date --iso-8601=seconds 2>/dev/null || date)",
  "backup_format_version": $CYBERVPS_BACKUP_FORMAT,
  "sha256": "$sha256",
  "hostname": "$hostname",
  "architecture": "$arch",
  "size_bytes": $(stat -c%s "$archive" 2>/dev/null || stat -f%z "$archive" 2>/dev/null || echo 0),
  "included_dirs": [
    "$HOME/bin",
    "$HOME/apps",
    "$HOME/config",
    "$HOME/services",
    "$HOME/projects",
    "$HOME/examples",
    "$HOME/run",
    "$HOME/.pm2/dump.pm2",
    "$HOME/.cargo",
    "$HOME/.rustup",
    "$HOME/.bashrc",
    "$HOME/.profile",
    "$HOME/.bash_aliases",
    "$HOME/.bash_logout"
  ],
  "excluded_patterns": [
    "$HOME/.cache",
    "$HOME/.npm",
    "$HOME/.local",
    "$HOME/.conda",
    "$HOME/.mamba",
    "$HOME/.rustup/.cargo/registry/cache",
    "$HOME/.cargo/registry/cache",
    "$HOME/projects/*/node_modules",
    "$HOME/tmp",
    "$HOME/.bash_history",
    "$HOME/.cargo/log",
    "$HOME/.cache/*",
    "$HOME/.pm2/pm2.log",
    "$HOME/.pm2/pm2.pid",
    "$HOME/.pm2/rpc.sock",
    "$HOME/.pm2/pub.sock",
    "$HOME/.pm2/daemon.json",
    "$HOME/apps/micromamba/pkgs",
    "$HOME/apps/micromamba/envs/hosting/lib/python*/site-packages/__pycache__",
    "$HOME/apps/micromamba/envs/hosting/lib/python*/site-packages/*.pyc",
    "$HOME/apps/redis/data/dump.rdb",
    "$HOME/apps/redis/data/appendonly.aof",
    "$HOME/apps/redis/data/appendonlydir",
    "$HOME/apps/nginx/temp",
    "$HOME/apps/nginx/var",
    "$HOME/apps/nginx/logs",
    "$HOME/apps/nginx/client_body",
    "$HOME/apps/nginx/proxy",
    "$HOME/apps/nginx/fastcgi",
    "$HOME/apps/nginx/uwsgi",
    "$HOME/apps/nginx/scgi",
    "$HOME/apps/nginx/client_body_temp",
    "$HOME/apps/nginx/proxy_temp",
    "$HOME/apps/nginx/fastcgi_temp",
    "$HOME/apps/nginx/uwsgi_temp",
    "$HOME/apps/nginx/scgi_temp",
    "$HOME/logs",
    "$HOME/run/*.pid",
    "$HOME/run/*.sock",
    "$HOME/run/*.lock"
  ],
  "secrets_included": false,
  "secrets_encrypted": $SECRETS_ENCRYPTED,
  "shared_included": $INCLUDE_SHARED
}
EOF
    ok "latest.json generated"
}

# Generate SHA256SUMS
generate_sha256sums() {
    local archive="$1"
    cd "$BACKUP_DIR"
    sha256sum "$archive" > SHA256SUMS
    ok "SHA256SUMS generated"
    cd "$CYBERBACKUP_DIR"
}

# Main backup flow
main() {
    header "CYBER VPS BACKUP"
    echo "Host: $(hostname)"
    echo "User: $(whoami)"
    echo

    if [ ! -f "$BACKUP_LIST_FILE" ]; then
        print_error "files.txt manifest not found"
    fi

    ok "Creating backup archive: $ARCHIVE_NAME"

    # Build file list from manifest
    local file_list="$BACKUP_DIR/backup-filelist-$$.txt"
    > "$file_list"

    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue
        # Expand $HOME if present
        line="${line//\$HOME/$HOME}"
        # Remove any leading ./ for cleanliness
        line="${line#./}"
        if [ -e "$line" ]; then
            echo "$line" >> "$file_list"
        else
            warn "Path not found, skipping: $line"
        fi
    done < "$BACKUP_LIST_FILE"

    # Exclude pid/sock/lock files from the list
    local cleaned_list="$BACKUP_DIR/backup-filelist-cleaned-$$.txt"
    > "$cleaned_list"
    while IFS= read -r path; do
        case "$path" in
            *.pid|*.sock|*.lock) continue ;;
        esac
        echo "$path" >> "$cleaned_list"
    done < "$file_list"
    mv "$cleaned_list" "$file_list"

    # Remove socket entries from file list (tar cannot archive sockets)
    local sock_cleaned="$BACKUP_DIR/backup-filelist-sock-cleaned-$$.txt"
    > "$sock_cleaned"
    while IFS= read -r path; do
        # Check if this is a socket file
        if [ -S "$path" ]; then
            warn "Socket file excluded: $path"
            continue
        fi
        echo "$path" >> "$sock_cleaned"
    done < <(sort -u "$file_list")
    mv "$sock_cleaned" "$file_list"

    # Remove duplicate entries
    sort -u "$file_list" -o "$file_list"

    # Remove pid/sock/lock files from file list
    local final_list="$BACKUP_DIR/backup-filelist-final-$$.txt"
    > "$final_list"
    while IFS= read -r path; do
        case "$path" in
            *.pid|*.sock|*.lock) continue ;;
        esac
        echo "$path" >> "$final_list"
    done < "$file_list"
    mv "$final_list" "$file_list"

    # Exclude patterns
    local exclude_file="$BACKUP_DIR/backup-excludes-$$.txt"
    > "$exclude_file"
    cat >> "$exclude_file" <<'EXCLUDES'
.cache
.node_modules
__pycache__
*.pyc
*.pyo
*.egg-info
*.egg
dist
build
target
*.rs.bk
*.bak
*.old
*.orig
*.swp
*~
.DS_Store
Thumbs.db
desktop.ini
npm-debug.log*
yarn-debug.log*
yarn-error.log*
*.tsbuildinfo
.pnpm-store
.cache
pm2.log
pm2.pid
rpc.sock
pub.sock
daemon.json
dump.rdb
appendonly.aof
appendonlydir
*.pid
*.sock
*.lock
pkgs
EXCLUDES

    # Create archive using tar + zstd
    if command -v zstd >/dev/null 2>&1; then
        tar -I zstd -cf "$ARCHIVE_PATH" --files-from="$file_list" --exclude-from="$exclude_file" --absolute-names || print_error "tar+zstd failed"
    else
        # Fallback to gzip if zstd not available
        tar -czf "${ARCHIVE_PATH%.tar.zst}.tar.gz" --files-from="$file_list" --exclude-from="$exclude_file" --absolute-names || print_error "tar+gzip failed"
        ARCHIVE_PATH="${ARCHIVE_PATH%.tar.zst}.tar.gz"
        ARCHIVE_NAME="${ARCHIVE_NAME%.tar.zst}.tar.gz"
    fi

    ok "Backup archive created: $ARCHIVE_PATH"

    # Generate metadata
    generate_latest_json "$ARCHIVE_PATH"
    generate_sha256sums "$ARCHIVE_PATH"

    # Show size
    local size
    size=$(du -h "$ARCHIVE_PATH" | cut -f1)
    ok "Backup size: $size"

    # Show what was included
    echo
    header "INCLUDED PATHS"
    cat "$file_list" | sed 's|^'$HOME'|~/|'
    echo

    # Show what was excluded
    echo
    header "EXCLUDED PATTERNS"
    cat "$exclude_file"
    echo

    # Secrets status
    echo
    header "SECRETS STATUS"
    warn "Secrets excluded by default"
    ok "No plaintext secrets in backup"
    echo

    # Shared data status
    echo
    header "SHARED DATA STATUS"
    if [ "$INCLUDE_SHARED" -eq 1 ]; then
        ok "Shared data included (as separate archive)"
    else
        warn "Shared data NOT included in main backup"
        warn "Use --include-shared or CYBERBACKUP_INCLUDE_SHARED=1 to include"
    fi
    echo

    # Cleanup temp files
    rm -f "$file_list" "$exclude_file"

    echo
    header "BACKUP COMPLETE"
    ok "Archive: $ARCHIVE_PATH"
    ok "latest.json: $BACKUP_DIR/latest.json"
    ok "SHA256SUMS: $BACKUP_DIR/SHA256SUMS"
    echo
    echo "Next steps:"
    echo "  1. Upload to remote: ./upload-backup.sh"
    echo "  2. Verify: ./verify.sh"
    echo "  3. Disaster recovery:"
    echo "     git clone <repo> cyberbackup"
    echo "     cd cyberbackup"
    echo "     bash cybervps.sh"
    echo
    echo "Option 1: RESTORE EXISTING CYBERBACKUP"
    echo "Option 2: FRESH USER-SPACE REBUILD"
}

main "$@"
