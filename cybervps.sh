#!/usr/bin/env bash
# cybervps.sh — CyberVPS Rootless Cloud Control Center (UI V3)
# Interactive terminal dashboard with resilient error boundary, pure ANSI/UTF-8 styling,
# centralized Bash execution dispatcher, and self-repair capabilities.
set -uo pipefail

CYBERVPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$CYBERVPS_DIR"

# shellcheck source=lib/common.sh
source "$CYBERVPS_DIR/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$CYBERVPS_DIR/lib/detect.sh"
# shellcheck source=lib/services.sh
source "$CYBERVPS_DIR/lib/services.sh"
# shellcheck source=lib/ports.sh
source "$CYBERVPS_DIR/lib/ports.sh"
# shellcheck source=lib/ui.sh
source "$CYBERVPS_DIR/lib/ui.sh"
# shellcheck source=lib/execution.sh
source "$CYBERVPS_DIR/lib/execution.sh"
# shellcheck source=lib/cyberroot.sh
source "$CYBERVPS_DIR/lib/cyberroot.sh"
# shellcheck source=lib/sessions.sh
source "$CYBERVPS_DIR/lib/sessions.sh"
# shellcheck source=lib/persistence.sh
source "$CYBERVPS_DIR/lib/persistence.sh"
# shellcheck source=lib/webterm.sh
source "$CYBERVPS_DIR/lib/webterm.sh"

# Ensure user PATH includes user-space locations
export PATH="$HOME/.local/bin:$HOME/bin:$HOME/apps/micromamba/envs/hosting/bin:$HOME/.cargo/bin:$HOME/go/bin:$HOME/apps/go/bin:$PATH"

# Run self-repair routine
run_self_repair() {
    clear 2>/dev/null || echo
    ui_header
    echo -e "${C_BCYAN}=== CyberVPS Self-Repair & Permission Normalizer ===${C_RESET}"
    echo

    # 1. Directory structures
    echo -n "• Verifying user-space directories... "
    for d in bin apps config services logs run backups downloads tmp; do
        ensure_directory "$HOME/$d" 0755
    done
    ensure_directory "${HOME}/.config/cybervps" 0700
    ensure_directory "${HOME}/.local/state/cybervps/logs" 0755
    echo -e "${C_BGREEN}OK${C_RESET}"

    # 2. Repair repository file permissions for user-owned files
    echo -n "• Checking repository file permissions... "
    local rep_count=0
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        if [ -O "$f" ]; then
            chmod u+r "$f" 2>/dev/null || true
            [[ "$f" == *.sh ]] && chmod u+x "$f" 2>/dev/null || true
            rep_count=$((rep_count + 1))
        fi
    done < <(find "$CYBERVPS_DIR" -type f \( -name "*.sh" -o -name "*.env" -o -name "*.json" \) 2>/dev/null)
    echo -e "${C_BGREEN}OK (${rep_count} files checked)${C_RESET}"

    # 3. Dynamic ports configuration
    echo -n "• Verifying ports configuration (ports.env)... "
    init_ports_config
    echo -e "${C_BGREEN}OK${C_RESET}"

    # 4. Helper scripts in ~/bin
    echo -n "• Rebuilding user-space CLI helpers (~/bin/cybervps-*)... "
    install_service_cli_helpers >/dev/null 2>&1 || true
    echo -e "${C_BGREEN}OK${C_RESET}"

    # 5. Shell execution test
    echo -n "• Testing internal Bash execution dispatch... "
    if run_cybervps_script "$CYBERVPS_DIR/lib/detect.sh" >/dev/null 2>&1; then
        echo -e "${C_BGREEN}OK (Operational)${C_RESET}"
    else
        echo -e "${C_BYELLOW}WARN (Check environment)${C_RESET}"
    fi

    echo
    ui_success "CyberVPS self-repair finished successfully."
    ui_pause
}

# View Status Menu
handle_status_menu() {
    clear 2>/dev/null || echo
    ui_header
    echo -e "${C_BCYAN}=== CyberVPS System Status & Active Services ===${C_RESET}"
    ui_kv "Version" "$CYBERVPS_VERSION"
    ui_kv "Backup Format" "Format Version $CYBERVPS_BACKUP_FORMAT"
    ui_kv "Process Manager" "$(get_process_backend)"
    ui_kv "User Home" "$CYBER_HOME"
    echo
    echo -e "${C_BWHITE}Discovered Local Backups:${C_RESET}"
    local found=0
    for b in "$CYBERVPS_DIR/downloads"/cybervps-backup-*.tar.*; do
        if [ -f "$b" ]; then
            local bsize
            bsize="$(du -h "$b" 2>/dev/null | awk '{print $1}')"
            echo -e "  ${C_BCYAN}•${C_RESET} $(basename "$b") ${C_DIM}(${bsize})${C_RESET}"
            found=1
        fi
    done
    [ "$found" -eq 0 ] && echo -e "  ${C_DIM}(No backups found in downloads/)${C_RESET}"
    ui_pause
}

# View Configuration Menu
handle_config_menu() {
    clear 2>/dev/null || echo
    ui_header
    echo -e "${C_BCYAN}=== CyberVPS Configuration Files ===${C_RESET}"
    ui_kv "Config File" "$CYBERVPS_CONFIG_FILE"
    ui_kv "Ports File" "$PORTS_CONFIG_FILE"
    echo
    if [ -f "$CYBERVPS_CONFIG_FILE" ]; then
        echo -e "${C_BWHITE}Current config.env:${C_RESET}"
        sed 's/^/  /' "$CYBERVPS_CONFIG_FILE"
    else
        echo -e "  ${C_DIM}(config.env not present; default runtime settings active)${C_RESET}"
    fi
    echo
    if [ -f "$PORTS_CONFIG_FILE" ]; then
        echo -e "${C_BWHITE}Current ports.env:${C_RESET}"
        sed 's/^/  /' "$PORTS_CONFIG_FILE"
    fi
    ui_pause
}

# View Diagnostics Menu
handle_diagnostics_menu() {
    clear 2>/dev/null || echo
    ui_header
    echo -e "${C_BCYAN}=== CyberVPS Diagnostics & System Inspector ===${C_RESET}"
    echo -e "${C_BWHITE}System Environment:${C_RESET}"
    ui_kv "Architecture" "$CYBER_ARCH ($CYBER_RAW_ARCH)"
    ui_kv "Kernel" "$CYBER_KERNEL"
    ui_kv "Distribution" "$CYBER_DISTRO_PRETTY"
    ui_kv "C Library" "$CYBER_LIBC $CYBER_LIBC_VERSION"
    ui_kv "User / UID" "$CYBER_USER / $CYBER_UID"

    # Package manager detection without sudo prompt
    local pkg_msg="None detected"
    if command -v apt >/dev/null 2>&1 || command -v apt-get >/dev/null 2>&1; then
        pkg_msg="APT detected — privileged installation unavailable (rootless)"
    elif command -v dnf >/dev/null 2>&1; then
        pkg_msg="DNF detected — privileged installation unavailable (rootless)"
    elif command -v pacman >/dev/null 2>&1; then
        pkg_msg="Pacman detected — privileged installation unavailable (rootless)"
    fi
    ui_kv "Package Mgr" "$pkg_msg"

    # Mount policy check
    local noexec_status="Allowed (standard)"
    check_filesystem_noexec "$CYBERVPS_DIR" && noexec_status="RESTRICTED (noexec mount detected)"
    ui_kv "Mount Policy" "$noexec_status"

    echo
    echo -e "${C_BWHITE}Process Backend Candidates:${C_RESET}"
    local sysd_ok="No" tmux_ok="No" screen_ok="No"
    if command -v systemctl >/dev/null 2>&1 && systemctl --user list-units >/dev/null 2>&1; then
        sysd_ok="Yes (active)"
    fi
    command -v tmux >/dev/null 2>&1 && tmux_ok="Yes"
    command -v screen >/dev/null 2>&1 && screen_ok="Yes"
    echo -e "  ${C_DIM}• systemd --user:${C_RESET} $sysd_ok"
    echo -e "  ${C_DIM}• tmux:          ${C_RESET} $tmux_ok"
    echo -e "  ${C_DIM}• screen:        ${C_RESET} $screen_ok"
    echo -e "  ${C_DIM}• nohup:         ${C_RESET} Yes (fallback)"
    echo -e "  ${C_BWHITE}Selected Default:${C_RESET} ${C_BCYAN}$(get_process_backend)${C_RESET}"

    echo
    echo -e "${C_BWHITE}Port Allocations & Listeners:${C_RESET}"
    if [ -f "$PORTS_CONFIG_FILE" ]; then
        while IFS='=' read -r k v || [ -n "$k" ]; do
            [[ -z "$k" || "$k" =~ ^# ]] && continue
            local state="inactive"
            is_port_free "$v" || state="LISTENING"
            printf "  %-18s = %-6s [%s]\n" "$k" "$v" "$state"
        done < "$PORTS_CONFIG_FILE"
    else
        echo -e "  ${C_DIM}(No ports.env allocated yet)${C_RESET}"
    fi

    echo
    echo -e "${C_BWHITE}Recent Activity Logs:${C_RESET}"
    local log_f="${HOME}/.local/state/cybervps/logs/cybervps.log"
    if [ -f "$log_f" ]; then
        tail -n 8 "$log_f" | sed 's/^/  /'
    else
        echo -e "  ${C_DIM}(No log entries recorded)${C_RESET}"
    fi
    echo
    local diag_act=""
    read -rp "Press Enter to return, or [E] to Export Report: " diag_act || true
    if [[ "$diag_act" =~ ^[eE] ]]; then
        echo
        run_cybervps_script "$CYBERVPS_DIR/scripts/cybervps-export-diagnostics.sh"
        ui_pause
    fi
}

# Resilient Action Dispatcher (Error Boundary)
# Guarantees main menu NEVER terminates when child scripts return non-zero
run_menu_action() {
    local action_title="$1"
    local script_file="$2"
    local log_slug="$3"
    shift 3

    local log_dir="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/logs"
    mkdir -p "$log_dir" 2>/dev/null || true
    local log_file="$log_dir/${log_slug}.log"

    clear 2>/dev/null || echo
    ui_header
    echo -e "${C_BCYAN}=== Action: ${action_title} ===${C_RESET}"
    echo -e "${C_DIM}Executing via Bash dispatcher; logging to: ${log_file}${C_RESET}"
    echo

    local exit_code=0
    # Execute child script through Bash execution engine
    # Pipe output to both console and per-operation log file
    run_cybervps_script "$script_file" "$@" 2>&1 | tee -a "$log_file" || exit_code=${PIPESTATUS[0]:-$?}

    echo
    if [ "$exit_code" -eq 0 ]; then
        ui_success "${action_title} completed successfully."
        ui_pause
    else
        local reason
        reason="$(interpret_exit_code "$exit_code")"
        ui_failure_card "$action_title" "$exit_code" "$reason" "$script_file" "$log_file"
        while true; do
            local sub_choice=""
            read -rp "Selection [Enter=Dashboard, L=View Log, D=Diagnostics]: " sub_choice || true
            case "$sub_choice" in
                [dD]*)
                    handle_diagnostics_menu
                    break
                    ;;
                [lL]*)
                    ui_view_log "$log_file" 30
                    break
                    ;;
                *)
                    break
                    ;;
            esac
        done
    fi
}

# Render V3 Dashboard
show_dashboard() {
    clear 2>/dev/null || echo
    ui_header

    ui_menu_section "RECOVERY" \
        "[1] Restore Backup Snapshot" \
        "[2] Fresh Install / Rootless Rebuild" \
        "[3] Migrate Backup From Another VPS"

    ui_menu_section "BACKUP & ARCHIVE" \
        "[4] Create Backup Snapshot" \
        "[5] Upload Backup to Remote Storage" \
        "[6] Download Backup from Remote Storage"

    ui_menu_section "SYSTEM & TOOLS" \
        "[7] Run VPS Health Verification" \
        "[8] View CyberVPS Status & Services" \
        "[9] Configuration Manager" \
        "[C] CyberRoot Rootless Linux Runtime" \
        "[D] System Diagnostics & Inspector" \
        "[R] Self-Repair & Permission Normalizer"

    local width
    width="$(ui_get_width)"
    local inner_width=$((width - 2))
    local line_h
    line_h="$(_ui_repeat "$UI_H" "$inner_width")"

    echo -e "  ${C_BWHITE}[0] Exit CyberVPS${C_RESET}"
    echo -e "${C_DIM}${UI_H}${line_h}${C_RESET}"
    echo -e "  ${C_DIM}CyberVPS v${CYBERVPS_VERSION} • Backup Format v${CYBERVPS_BACKUP_FORMAT} • ROOTLESS CLOUD MODE${C_RESET}"
    echo
}

_SIGINT_COUNT=0
handle_sigint() {
    _SIGINT_COUNT=$((_SIGINT_COUNT + 1))
    if [ "$_SIGINT_COUNT" -ge 2 ]; then
        echo -e "\n${C_BCYAN}Exiting CyberVPS. Goodbye!${C_RESET}"
        exit 0
    fi
    echo
    echo -e "${C_BYELLOW}[Interrupted]${C_RESET} ${C_WHITE}Press Ctrl+C again or [0] to exit, or Enter to continue.${C_RESET}"
    (sleep 3 && _SIGINT_COUNT=0) >/dev/null 2>&1 &
}

# Master interactive event loop
main_loop() {
    # Trap Ctrl+C cleanly in interactive menu
    trap 'handle_sigint' SIGINT

    while true; do
        show_dashboard
        local choice=""
        if ! read -rp "Enter Selection: " choice; then
            echo -e "${C_DIM}EOF encountered. Exiting CyberVPS.${C_RESET}"
            break
        fi
        echo

        case "$choice" in
            1)
                run_menu_action "Restore Backup" "$CYBERVPS_DIR/restore.sh" "restore"
                ;;
            2)
                run_menu_action "Fresh Rootless Rebuild" "$CYBERVPS_DIR/fresh-install.sh" "fresh-install"
                ;;
            3)
                run_menu_action "Migrate Backup" "$CYBERVPS_DIR/migrate.sh" "migration"
                ;;
            4)
                run_menu_action "Create Backup" "$CYBERVPS_DIR/backup-now.sh" "backup"
                ;;
            5)
                run_menu_action "Upload Backup" "$CYBERVPS_DIR/upload-backup.sh" "upload"
                ;;
            6)
                run_menu_action "Download Backup" "$CYBERVPS_DIR/download-backup.sh" "download"
                ;;
            7)
                run_menu_action "VPS Health Verification" "$CYBERVPS_DIR/verify.sh" "verify"
                ;;
            8)
                handle_status_menu
                ;;
            9)
                handle_config_menu
                ;;
            [cC]*)
                handle_cyberroot_menu
                ;;
            10|[dD]*)
                handle_diagnostics_menu
                ;;
            [rR]*)
                run_self_repair
                ;;
            0|[qQ]*)
                echo -e "${C_BCYAN}Exiting CyberVPS. Goodbye!${C_RESET}"
                exit 0
                ;;
            *)
                ui_warning "Invalid selection: '$choice'. Please choose from the menu options."
                sleep 1
                ;;
        esac
    done
}

# CLI Argument handling
if [ "${1:-}" = "--repair" ]; then
    run_self_repair
    exit 0
elif [ "${1:-}" = "session" ]; then
    shift
    handle_session_cli "$@"
    exit $?
elif [ "${1:-}" = "service" ]; then
    shift
    handle_service_cli "$@"
    exit $?
elif [ "${1:-}" = "persistence" ]; then
    shift
    handle_persistence_cli "$@"
    exit $?
elif [ "${1:-}" = "webterm" ]; then
    shift
    handle_webterm_cli "$@"
    exit $?
elif [ "${1:-}" = "--menu" ] || [ -t 0 ]; then
    main_loop
else
    show_dashboard
    echo "Non-interactive session. Use direct script execution via Bash:"
    echo "  bash backup-now.sh, bash restore.sh, bash fresh-install.sh, bash verify.sh"
    echo "  cybervps session <command>"
    echo "  cybervps service <command>"
    echo "  cybervps persistence <command>"
    echo "  cybervps webterm <command>"
    exit 0
fi
