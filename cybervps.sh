#!/usr/bin/env bash
# cybervps.sh — CyberVPS Master Interactive Terminal Interface
# Provides a rootless menu for Backup, Restore, Migration, and Disaster Recovery.
set -euo pipefail

CYBERVPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$CYBERVPS_DIR"

# shellcheck source=lib/common.sh
source "$CYBERVPS_DIR/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$CYBERVPS_DIR/lib/detect.sh"
# shellcheck source=lib/services.sh
source "$CYBERVPS_DIR/lib/services.sh"

# Ensure user PATH includes user-space locations
export PATH="$HOME/bin:$HOME/apps/micromamba/envs/hosting/bin:$HOME/.cargo/bin:$HOME/go/bin:$HOME/apps/go/bin:$PATH"

# Test Unicode support
has_unicode() {
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *UTF-8*|*utf8*) return 0 ;;
        *) return 1 ;;
    esac
}

show_header() {
    clear 2>/dev/null || echo
    if has_unicode; then
        cat << 'EOF'
╔══════════════════════════════════════════════════════╗
║                       CyberVPS                       ║
║        Portable Non-Root Linux Recovery Toolkit      ║
╚══════════════════════════════════════════════════════╝
EOF
    else
        cat << 'EOF'
+------------------------------------------------------+
|                       CyberVPS                       |
|        Portable Non-Root Linux Recovery Toolkit      |
+------------------------------------------------------+
EOF
    fi

    detect_environment
    echo "Detected Profile:"
    echo "  Host: $CYBER_HOSTNAME | User: $CYBER_USER | Arch: $CYBER_ARCH"
    echo "  Home: $CYBER_HOME"
    echo "  OS:   $CYBER_DISTRO_PRETTY ($CYBER_LIBC $CYBER_LIBC_VERSION)"
    echo "--------------------------------------------------------"
}

show_menu() {
    show_header
    cat << 'EOF'
  [1] Restore Backup to This VPS
  [2] Fresh Install / Rebuild
  [3] Migrate Backup From Another VPS
  [4] Create Backup
  [5] Upload Backup
  [6] Download Backup
  [7] Verify Current VPS
  [8] CyberVPS Status
  [9] Configuration
  [10] Diagnostics & System Inspector
  [0] Exit
--------------------------------------------------------
EOF
}

handle_config_menu() {
    show_header
    echo "=== CyberVPS Configuration ==="
    echo "Config file: $CYBERVPS_CONFIG_FILE"
    echo "Ports file:  $PORTS_CONFIG_FILE"
    echo
    if [ -f "$CYBERVPS_CONFIG_FILE" ]; then
        echo "--- Current config.env ---"
        cat "$CYBERVPS_CONFIG_FILE"
    else
        echo "No config.env file found. Defaults are active."
    fi
    echo
    if [ -f "$PORTS_CONFIG_FILE" ]; then
        echo "--- Current ports.env ---"
        cat "$PORTS_CONFIG_FILE"
    fi
    echo
    read -rp "Press Enter to return to main menu..." _
}

handle_status_menu() {
    show_header
    echo "=== CyberVPS Status & Services ==="
    echo "Application Version: $CYBERVPS_VERSION"
    echo "Backup Format:       $CYBERVPS_BACKUP_FORMAT"
    echo "Process Backend:     $(get_process_backend)"
    echo
    echo "Local Backups:"
    local found=0
    for b in "$CYBERVPS_DIR/downloads"/cybervps-backup-*.tar.*; do
        if [ -f "$b" ]; then
            echo "  - $(basename "$b") ($(du -h "$b" | awk '{print $1}'))"
            found=1
        fi
    done
    [ "$found" -eq 0 ] && echo "  (None found in downloads/)"
    echo
    read -rp "Press Enter to return to main menu..." _
}

handle_diagnostics_menu() {
    show_header
    echo "=== CyberVPS Diagnostics & System Inspector ==="
    echo "Host Profile:"
    echo "  Architecture:  $CYBER_ARCH ($CYBER_RAW_ARCH)"
    echo "  Kernel:        $CYBER_KERNEL"
    echo "  Distribution:  $CYBER_DISTRO_PRETTY"
    echo "  C Library:     $CYBER_LIBC $CYBER_LIBC_VERSION"
    echo "  User / UID:    $CYBER_USER / $CYBER_UID"
    echo
    echo "Service Backend Candidates:"
    local sysd_ok="No" tmux_ok="No" screen_ok="No"
    if have_command systemctl && systemctl --user list-units >/dev/null 2>&1; then
        sysd_ok="Yes (active)"
    fi
    have_command tmux && tmux_ok="Yes"
    have_command screen && screen_ok="Yes"
    echo "  - systemd --user: $sysd_ok"
    echo "  - tmux:           $tmux_ok"
    echo "  - screen:         $screen_ok"
    echo "  - nohup:          Yes (fallback)"
    echo "  Selected Default: $(get_process_backend)"
    echo
    echo "Port Allocations & Active Bindings:"
    if [ -f "$PORTS_CONFIG_FILE" ]; then
        while IFS='=' read -r k v || [ -n "$k" ]; do
            [[ -z "$k" || "$k" =~ ^# ]] && continue
            local listening="inactive"
            is_port_free "$v" || listening="LISTENING"
            printf "  %-18s = %-6s [%s]\n" "$k" "$v" "$listening"
        done < "$PORTS_CONFIG_FILE"
    else
        echo "  (No ports.env initialized yet)"
    fi
    echo
    echo "Recent CyberVPS Activity Logs:"
    local log_f="${HOME}/.local/state/cybervps/logs/cybervps.log"
    if [ -f "$log_f" ]; then
        tail -n 12 "$log_f" | sed 's/^/  /'
    else
        echo "  (No log entries recorded)"
    fi
    echo
    read -rp "Press Enter to return to main menu..." _
}

main_loop() {
    while true; do
        show_menu
        local choice
        read -rp "Selection [0-10]: " choice
        echo
        case "$choice" in
            1)
                "$CYBERVPS_DIR/restore.sh"
                read -rp "Press Enter to continue..." _
                ;;
            2)
                "$CYBERVPS_DIR/fresh-install.sh"
                read -rp "Press Enter to continue..." _
                ;;
            3)
                "$CYBERVPS_DIR/migrate.sh"
                read -rp "Press Enter to continue..." _
                ;;
            4)
                "$CYBERVPS_DIR/backup-now.sh"
                read -rp "Press Enter to continue..." _
                ;;
            5)
                "$CYBERVPS_DIR/upload-backup.sh"
                read -rp "Press Enter to continue..." _
                ;;
            6)
                "$CYBERVPS_DIR/download-backup.sh"
                read -rp "Press Enter to continue..." _
                ;;
            7)
                "$CYBERVPS_DIR/verify.sh"
                read -rp "Press Enter to continue..." _
                ;;
            8)
                handle_status_menu
                ;;
            9)
                handle_config_menu
                ;;
            10)
                handle_diagnostics_menu
                ;;
            0)
                echo "Exiting CyberVPS. Goodbye!"
                exit 0
                ;;
            *)
                echo "Invalid selection: $choice"
                sleep 1
                ;;
        esac
    done
}

if [ "${1:-}" = "--menu" ] || [ -t 0 ]; then
    main_loop
else
    show_menu
    echo "Non-interactive session. Use CLI scripts directly:"
    echo "  ./backup-now.sh, ./restore.sh, ./fresh-install.sh, ./verify.sh"
fi
