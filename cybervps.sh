#!/usr/bin/env bash
# cybervps.sh — CyberVPS Backup & Recovery main entry
# Displays recovery menu and dispatches to restore.sh or fresh-install.sh
set -euo pipefail

# Ensure PATH includes user bin and micromamba hosting env
export PATH="$HOME/bin:$HOME/apps/micromamba/envs/hosting/bin:$HOME/.cargo/bin:$HOME/go/bin:$HOME/apps/go/bin:$PATH"
CYBERBACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$CYBERBACKUP_DIR"

# Colors
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
blue='\033[0;34m'
bold='\033[1m'
reset='\033[0m'

# Helper
info()    { echo -e "${info}${reset} $*"; }
ok()      { echo -e "${green}✔${reset} $*"; }
warn()    { echo -e "${yellow}⚠${reset} $*"; }
err()     { echo -e "${red}✖${reset} $*"; }
header()  { echo -e "\n${bold}$*${reset}\n"; }

# Check for backups directory
BACKUP_DIR="$HOME/cyberbackup/downloads"
mkdir -p "$BACKUP_DIR"

# Detect latest backup archive if present
detect_backup() {
    local latest="$BACKUP_DIR/latest.json"
    if [ -f "$latest" ]; then
        return 0
    fi
    # Also accept commonly named archives
    for c in "$BACKUP_DIR"/cybervps-backup-*.tar.zst "$BACKUP_DIR"/cybervps-backup-*.tar.gz; do
        if [ -f "$c" ]; then
            return 0
        fi
    done
    return 1
}

# Show main menu
show_menu() {
    clear
    cat <<'EOF'
╔══════════════════════════════════════╗
║         CYBER VPS RECOVERY           ║
╚══════════════════════════════════════╝

Host: $(hostname)
User: $(whoami)

[1] Restore from CyberBackup
[2] Fresh Install / Rebuild
[0] Exit

Selection:
EOF
}

# Read selection
read_selection() {
    local choice
    read -rp "Selection: " choice
    echo
    case "$choice" in
        1)
            "$CYBERBACKUP_DIR/restore.sh"
            ;;
        2)
            "$CYBERBACKUP_DIR/fresh-install.sh"
            ;;
        0)
            echo "Exiting."
            exit 0
            ;;
        *)
            err "Invalid selection: $choice"
            sleep 1
            show_menu
            read_selection
            ;;
    esac
}

# Ensure micromamba is available for restore/fresh paths
ensure_micromamba() {
    if command -v micromamba >/dev/null 2>&1; then
        ok "micromamba available"
        return 0
    fi
    warn "micromamba not in PATH"
    if [ -x "$HOME/bin/micromamba" ]; then
        export PATH="$HOME/bin:$PATH"
        ok "micromamba found at $HOME/bin/micromamba"
        return 0
    fi
    err "micromamba missing. Option 2 will attempt to download it."
    return 1
}

# Pre-flight
main() {
    header "CYBER VPS RECOVERY SYSTEM"
    echo "Host: $(hostname)"
    echo "User: $(whoami)"
    echo

    # Check for local backup
    if detect_backup; then
        ok "Local backup detected in $BACKUP_DIR"
    else
        warn "No local backup detected in $BACKUP_DIR"
        if [ -f "$CYBERBACKUP_DIR/remote.conf" ]; then
            if [ -n "${CYBERBACKUP_REMOTE:-}" ]; then
                ok "Remote backup configured: $CYBERBACKUP_REMOTE"
            else
                warn "No remote backup configured yet"
            fi
        else
            warn "No remote.conf found; copy remote.example.conf to remote.conf"
        fi
    fi

    echo
    show_menu
    read_selection
}

main "$@"
