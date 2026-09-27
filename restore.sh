#!/usr/bin/env bash
# restore.sh — restore from CyberBackup archive
set -euo pipefail

CYBERBACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$CYBERBACKUP_DIR"

BACKUP_DIR="$HOME/cyberbackup/downloads"
STAGING_DIR="$HOME/cyberbackup/payload/staging"
LOG="$CYBERBACKUP_DIR/logs/restore.log"
mkdir -p "$BACKUP_DIR" "$STAGING_DIR" "$(dirname "$LOG")"

exec > >(tee -a "$LOG") 2>&1

CYBERVPS_BACKUP_FORMAT=1

# Colors
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
blue='\033[0;34m'
bold='\033[1m'
reset='\033[0m'
info()    { echo -en "${info}${reset} $*"; }
ok()      { echo -e "${green}✔${reset} $*"; }
warn()    { echo -e "${yellow}⚠${reset} $*"; }
err()     { echo -e "${red}✖${reset} $*"; }
header()  { echo -e "\n${bold}$*${reset}\n"; }

print_error() { err "$@"; exit 1; }

# Load remote config if present
REMOTE_CONF="$CYBERBACKUP_DIR/remote.conf"
if [ -f "$REMOTE_CONF" ]; then
    # shellcheck disable=SC1091
    . "$REMOTE_CONF"
fi

# Detect local backup
detect_local_backup() {
    local latest="$BACKUP_DIR/latest.json"
    if [ -f "$latest" ]; then
        echo "$latest"
        return 0
    fi
    local candidates=(
        "$BACKUP_DIR/cybervps-backup-"*.tar.zst
        "$BACKUP_DIR/cybervps-backup-"*.tar.gz
    )
    for c in "${candidates[@]}"; do
        if [ -f "$c" ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

# Verify SHA256
verify_checksum() {
    local archive="$1"
    local checksum_file="$2"
    if [ ! -f "$checksum_file" ]; then
        err "SHA256SUMS not found at $checksum_file"
        return 1
    fi
    local expected
    expected=$(grep -F "$(basename "$archive")" "$checksum_file" | awk '{print $1}')
    if [ -z "$expected" ]; then
        err "Checksum for $archive not found in SHA256SUMS"
        return 1
    fi
    local actual
    actual=$(sha256sum "$archive" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
        err "SHA256 mismatch for $archive"
        err "Expected: $expected"
        err "Actual:   $actual"
        return 1
    fi
    ok "SHA256 verified for $archive"
    return 0
}

# Extract archive
extract_archive() {
    local archive="$1"
    local target="$2"
    mkdir -p "$target"
    if [[ "$archive" == *.tar.zst ]]; then
        if command -v zstd >/dev/null 2>&1; then
            zstd -dc "$archive" | tar -xf - -C "$target"
        else
            err "zstd not found; cannot extract .tar.zst"
            return 1
        fi
    elif [[ "$archive" == *.tar.gz ]]; then
        tar -xzf "$archive" -C "$target"
    elif [[ "$archive" == *.tar ]]; then
        tar -xf "$archive" -C "$target"
    elif [[ "$archive" == *.zip ]]; then
        unzip -o "$archive" -d "$target"
    else
        err "Unsupported archive format: $archive"
        return 1
    fi
    ok "Extracted to $target"
}

# Restore user-space directories from staging
restore_user_space() {
    local staging="$1"
    local restore_prefix="$HOME"

    # Create pre-restore backup of existing important config
    local prerestore="$HOME/backups/pre-restore-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$prerestore"
    warn "Creating pre-restore backup in $prerestore"
    for dir in bin apps config services projects examples run .pm2 .cargo .rustup; do
        if [ -e "$HOME/$dir" ]; then
            cp -a "$HOME/$dir" "$prerestore/" 2>/dev/null || true
        fi
    done
    ok "Pre-restore backup created"

    # Restore directories from staging
    if [ -d "$staging/home" ]; then
        warn "Restoring user-space directories from staging..."
        for dir in bin apps config services projects examples run .pm2 .cargo .rustup; do
            if [ -e "$staging/home/$dir" ]; then
                if [ -e "$restore_prefix/$dir" ]; then
                    warn "Backing up existing $dir before restore"
                    cp -a "$restore_prefix/$dir" "$prerestore/${dir}.bak" 2>/dev/null || true
                fi
                cp -a "$staging/home/$dir" "$restore_prefix/$dir"
                ok "Restored $dir"
            fi
        done
    fi
}

# Restore micromamba
restore_micromamba() {
    local staging="$1"
    local micromamba_bin="$HOME/bin/micromamba"
    local micromamba_root="$HOME/apps/micromamba"

    ok "Checking micromamba..."

    if [ -x "$micromamba_bin" ]; then
        ok "micromamba already present"
        return 0
    fi

    # Try portable archive from backup
    if [ -f "$staging/home/apps/micromamba/envs/hosting/conda-meta/history" ] || [ -d "$staging/home/apps/micromamba" ]; then
        warn "Micromamba found in backup; restoring portable environment"
        mkdir -p "$micromamba_root"
        cp -a "$staging/home/apps/micromamba/." "$micromamba_root/"
        ok "Micromamba restored from backup"
        return 0
    fi

    # Recreate from manifest
    warn "Recreating micromamba from manifest..."
    local env_yml="$CYBERBACKUP_DIR/manifests/micromamba-env.yml"
    if [ ! -f "$env_yml" ]; then
        err "micromamba-env.yml not found; cannot recreate environment"
        return 1
    fi
    warn "Using micromamba-env.yml to recreate hosting environment"
    # This requires micromamba to be installed; handled by caller
    ok "Micromamba recreation prepared (requires micromamba binary)"
}

# Restore Python
restore_python() {
    local staging="$1"
    local pip_freeze="$CYBERBACKUP_DIR/manifests/pip-freeze.txt"
    if [ ! -f "$pip_freeze" ]; then
        err "pip-freeze.txt not found"
        return 1
    fi
    ok "Re Installing Python packages from pip-freeze.txt..."
    python -m pip install -r "$pip_freeze" || warn "Some Python packages may have failed to install"
}

# Restore Node
restore_node() {
    local staging="$1"
    local npm_global="$CYBERBACKUP_DIR/manifests/npm-global.txt"
    if [ ! -f "$npm_global" ]; then
        err "npm-global.txt not found"
        return 1
    fi
    ok "Installing npm global packages..."
    npm install -g $(cat "$npm_global" | tr '\n' ' ') || warn "Some npm packages may have failed"
}

# Restore Rust
restore_rust() {
    local staging="$1"
    local rust_version="$CYBERBACKUP_DIR/manifests/rust-version.txt"
    if [ ! -f "$rust_version" ]; then
        err "rust-version.txt not found"
        return 1
    fi
    ok "Rust manifest present; reinstall via rustup if needed"
    # rustup default stable
}

# Restore Go
restore_go() {
    local staging="$1"
    local go_version="$CYBERBACKUP_DIR/manifests/go-version.txt"
    if [ ! -f "$go_version" ]; then
        err "go-version.txt not found"
        return 1
    fi
    ok "Go manifest present; reinstall Go if needed"
}

# Restore Redis
restore_redis() {
    local staging="$1"
    ok "Redis config restore is placeholder; ensure $HOME/apps/redis exists"
}

# Restore nginx
restore_nginx() {
    local staging="$1"
    ok "nginx restore is placeholder; ensure $HOME/apps/nginx exists"
}

# Restore Supervisor
restore_supervisor() {
    local staging="$1"
    ok "Supervisor restore is placeholder; ensure $HOME/bin/svcd-h24 exists"
}

# Restore PM2
restore_pm2() {
    local staging="$1"
    if [ -f "$staging/home/.pm2/dump.pm2" ]; then
        ok "PM2 dump found; will resurrect after start"
    else
        warn "No PM2 dump found"
    fi
}

# Restore cloudflared
restore_cloudflared() {
    local staging="$1"
    ok "Cloudflared restore is placeholder; ensure $HOME/bin/cloudflared exists"
}

# Restore shell config
restore_shell() {
    local staging="$1"
    ok "Shell config restore is placeholder; ensure .bashrc/.profile exist"
}

# Start hosting stack
start_hosting() {
    ok "Starting hosting stack..."
    if [ -x "$HOME/bin/hosting-start" ]; then
        "$HOME/bin/hosting-start" || warn "hosting-start failed"
    else
        err "hosting-start not found"
    fi
    if [ -x "$HOME/bin/hosting-status" ]; then
        "$HOME/bin/hosting-status" || true
    fi
    if [ -x "$HOME/bin/vps-status" ]; then
        "$HOME/bin/vps-status" || true
    fi
    if [ -x "$HOME/services/healthcheck.sh" ]; then
        "$HOME/services/healthcheck.sh" || true
    fi
}

# Main restore flow
main() {
    header "RESTORE FROM CYBERBACKUP"
    echo "Host: $(hostname)"
    echo "User: $(whoami)"
    echo

    local archive=""
    local checksum_file=""

    if detect_local_backup >/dev/null 2>&1; then
        archive=$(detect_local_backup)
        checksum_file="$BACKUP_DIR/SHA256SUMS"
        ok "Local backup found: $archive"
    else
        err "No local backup found"
        err "Configure remote.conf or provide backup manually"
        exit 1
    fi

    if [ ! -f "$archive" ]; then
        print_error "Backup archive not found"
    fi

    if [ ! -f "$checksum_file" ]; then
        print_error "SHA256SUMS not found"
    fi

    header "Verifying backup integrity"
    verify_checksum "$archive" "$checksum_file" || print_error "Checksum verification failed"

    header "Extracting backup to staging"
    rm -rf "$STAGING_DIR"
    mkdir -p "$STAGING_DIR"
    extract_archive "$archive" "$STAGING_DIR" || print_error "Extraction failed"

    header "Restoring user-space environment"
    restore_user_space "$STAGING_DIR" || print_error "User space restore failed"
    restore_micromamba "$STAGING_DIR" || warn "Micromamba restore had issues"
    restore_python "$STAGING_DIR" || warn "Python restore had issues"
    restore_node "$STAGING_DIR" || warn "Node restore had issues"
    restore_rust "$STAGING_DIR" || warn "Rust restore had issues"
    restore_go "$STAGING_DIR" || warn "Go restore had issues"
    restore_redis "$STAGING_DIR" || warn "Redis restore had issues"
    restore_nginx "$STAGING_DIR" || warn "nginx restore had issues"
    restore_supervisor "$STAGING_DIR" || warn "Supervisor restore had issues"
    restore_pm2 "$STAGING_DIR" || warn "PM2 restore had issues"
    restore_cloudflared "$STAGING_DIR" || warn "Cloudflared restore had issues"
    restore_shell "$STAGING_DIR" || warn "Shell restore had issues"

    header "Starting hosting services"
    start_hosting || warn "Hosting start had issues"

    header "RESTORE COMPLETE"
    ok "Restore finished. Verify with: hosting-status ; vps-status ; ~/services/healthcheck.sh"
}

main "$@"
