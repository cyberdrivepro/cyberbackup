#!/usr/bin/env bash
# cybervps.sh — CyberVPS Infrastructure Control Center (UI V3)
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
# shellcheck source=lib/tunnel.sh
source "$CYBERVPS_DIR/lib/tunnel.sh"
# shellcheck source=lib/telegram.sh
source "$CYBERVPS_DIR/lib/telegram.sh"
# shellcheck source=lib/jobs.sh
source "$CYBERVPS_DIR/lib/jobs.sh"
# shellcheck source=lib/proot.sh
source "$CYBERVPS_DIR/lib/proot.sh"
# shellcheck source=lib/auto.sh
source "$CYBERVPS_DIR/lib/auto.sh"
# shellcheck source=lib/connect.sh
source "$CYBERVPS_DIR/lib/connect.sh"
# shellcheck source=lib/public.sh
source "$CYBERVPS_DIR/lib/public.sh"
# shellcheck source=lib/fleet.sh
source "$CYBERVPS_DIR/lib/fleet.sh"
# shellcheck source=lib/transfer.sh
source "$CYBERVPS_DIR/lib/transfer.sh"
source "$CYBERVPS_DIR/lib/cli.sh"

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

    # 2. Entrypoint script permissions (safe normalization of known scripts)
    for s in cybervps.sh fresh-install.sh verify.sh migrate.sh backup-now.sh restore.sh upload-backup.sh download-backup.sh; do
        if [ -f "$CYBERVPS_DIR/$s" ] && [ -w "$CYBERVPS_DIR/$s" ]; then
            chmod 0755 "$CYBERVPS_DIR/$s" 2>/dev/null || true
        fi
    done

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
        sed -E 's/^([^#=]*(TOKEN|PASS|SECRET|KEY|COOKIE|AUTH)[^=]*)=.*/\1=[REDACTED]/I; s/^/  /' "$CYBERVPS_CONFIG_FILE"
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

    print_capability_summary

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
    elif [ "$exit_code" -eq 10 ]; then
        local reason
        reason="$(interpret_exit_code "$exit_code")"
        ui_warning "${action_title} completed with warnings: ${reason}"
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

# ==============================================================================
# SUBMENUS FOR HOSTING & REMOTE OPERATIONS (V4)
# ==============================================================================

# Submenu: Service Manager
handle_services_submenu() {
    while true; do
        clear 2>/dev/null || echo
        ui_header
        echo -e "${C_BCYAN}=== CyberVPS Rootless Service Manager ===${C_RESET}"
        echo
        service_list
        echo
        echo -e "  ${C_BWHITE}[1]${C_RESET} List Services"
        echo -e "  ${C_BWHITE}[2]${C_RESET} Start Service"
        echo -e "  ${C_BWHITE}[3]${C_RESET} Stop Service"
        echo -e "  ${C_BWHITE}[4]${C_RESET} Restart Service"
        echo -e "  ${C_BWHITE}[5]${C_RESET} View Service Logs"
        echo -e "  ${C_BWHITE}[6]${C_RESET} Enable Service Autostart"
        echo -e "  ${C_BWHITE}[7]${C_RESET} Disable Service Autostart"
        echo -e "  ${C_BWHITE}[0]${C_RESET} Return to Main Menu"
        echo
        local choice=""
        read -rp "Service Action: " choice || break
        case "$choice" in
            1)
                clear 2>/dev/null || echo
                service_list
                ui_pause
                ;;
            2)
                local sname=""
                read -rp "Service name to start: " sname
                [ -n "$sname" ] && service_start "$sname"
                ui_pause
                ;;
            3)
                local sname=""
                read -rp "Service name to stop: " sname
                [ -n "$sname" ] && service_stop "$sname"
                ui_pause
                ;;
            4)
                local sname=""
                read -rp "Service name to restart: " sname
                [ -n "$sname" ] && service_restart "$sname"
                ui_pause
                ;;
            5)
                local sname=""
                read -rp "Service name to view logs: " sname
                [ -n "$sname" ] && service_logs "$sname" 30
                ui_pause
                ;;
            6)
                local sname=""
                read -rp "Service name to enable autostart: " sname
                [ -n "$sname" ] && service_enable "$sname"
                ui_pause
                ;;
            7)
                local sname=""
                read -rp "Service name to disable autostart: " sname
                [ -n "$sname" ] && service_disable "$sname"
                ui_pause
                ;;
            0|[qQ]*)
                break
                ;;
        esac
    done
}

# Submenu: Persistent Terminals
handle_sessions_submenu() {
    while true; do
        clear 2>/dev/null || echo
        ui_header
        echo -e "${C_BCYAN}=== CyberVPS Persistent Terminal Sessions ===${C_RESET}"
        echo
        session_list
        echo
        echo -e "  ${C_BWHITE}[1]${C_RESET} List Active Sessions"
        echo -e "  ${C_BWHITE}[2]${C_RESET} Create New Session"
        echo -e "  ${C_BWHITE}[3]${C_RESET} Attach to Session"
        echo -e "  ${C_BWHITE}[4]${C_RESET} Stop Session"
        echo -e "  ${C_BWHITE}[5]${C_RESET} View Session Logs"
        echo -e "  ${C_BWHITE}[6]${C_RESET} Clean Terminated Sessions"
        echo -e "  ${C_BWHITE}[0]${C_RESET} Return to Main Menu"
        echo
        local choice=""
        read -rp "Terminal Action: " choice || break
        case "$choice" in
            1)
                clear 2>/dev/null || echo
                session_list
                ui_pause
                ;;
            2)
                local sname="" scmd=""
                read -rp "Session name: " sname
                read -rp "Initial command (leave empty for shell): " scmd
                [ -n "$sname" ] && session_new "$sname" "$scmd"
                ui_pause
                ;;
            3)
                local sname=""
                read -rp "Session name to attach: " sname
                if [ -n "$sname" ]; then
                    session_attach "$sname"
                fi
                ;;
            4)
                local sname=""
                read -rp "Session name to stop: " sname
                [ -n "$sname" ] && session_stop "$sname"
                ui_pause
                ;;
            5)
                local sname=""
                read -rp "Session name to view logs: " sname
                [ -n "$sname" ] && session_logs "$sname" 30
                ui_pause
                ;;
            6)
                session_clean
                ui_pause
                ;;
            0|[qQ]*)
                break
                ;;
        esac
    done
}

# Submenu: Authenticated Web Terminal
handle_webterm_submenu() {
    while true; do
        clear 2>/dev/null || echo
        ui_header
        echo -e "${C_BCYAN}=== CyberVPS Authenticated Browser Web Terminal ===${C_RESET}"
        echo
        webterm_status
        echo
        echo -e "  ${C_BWHITE}[1]${C_RESET} View Status & Connection Info"
        echo -e "  ${C_BWHITE}[2]${C_RESET} Start Web Terminal (ttyd)"
        echo -e "  ${C_BWHITE}[3]${C_RESET} Stop Web Terminal"
        echo -e "  ${C_BWHITE}[4]${C_RESET} Set / Change Password"
        echo -e "  ${C_BWHITE}[5]${C_RESET} View Web Terminal Logs"
        echo -e "  ${C_BWHITE}[0]${C_RESET} Return to Main Menu"
        echo
        local choice=""
        read -rp "Web Terminal Action: " choice || break
        case "$choice" in
            1)
                clear 2>/dev/null || echo
                webterm_status
                ui_pause
                ;;
            2)
                webterm_start
                ui_pause
                ;;
            3)
                webterm_stop
                ui_pause
                ;;
            4)
                local u="" p=""
                read -rp "Username: " u
                read -s -rp "Password: " p
                echo
                if [ -n "$u" ] && [ -n "$p" ]; then
                    webterm_set_password "$u" "$p"
                fi
                ui_pause
                ;;
            5)
                webterm_logs 30
                ui_pause
                ;;
            0|[qQ]*)
                break
                ;;
        esac
    done
}

# Submenu: Telegram Heartbeat Settings
handle_heartbeat_settings_menu() {
    while true; do
        clear 2>/dev/null || echo
        ui_header
        echo -e "${C_BCYAN}=== Telegram Heartbeat Configuration ===${C_RESET}"
        echo
        telegram_status
        echo
        echo -e "  ${C_BWHITE}[1]${C_RESET} Enable Heartbeat (7 min compact)"
        echo -e "  ${C_BWHITE}[2]${C_RESET} Set Custom Interval (minutes)"
        echo -e "  ${C_BWHITE}[3]${C_RESET} Toggle Mode (compact vs message)"
        echo -e "  ${C_BWHITE}[4]${C_RESET} Disable Heartbeat"
        echo -e "  ${C_BWHITE}[0]${C_RESET} Return to Telegram Menu"
        echo
        local choice=""
        read -rp "Heartbeat Option: " choice || break
        case "$choice" in
            1)
                telegram_configure_heartbeat "true" 7 "compact"
                ui_pause
                ;;
            2)
                local int_m=""
                read -rp "Enter interval in minutes (5-60): " int_m
                if [[ "$int_m" =~ ^[0-9]+$ ]] && [ "$int_m" -ge 1 ]; then
                    telegram_configure_heartbeat "true" "$int_m" "compact"
                else
                    ui_warning "Invalid interval: $int_m"
                fi
                ui_pause
                ;;
            3)
                local m=""
                read -rp "Choose mode (compact / message): " m
                if [ "$m" = "compact" ] || [ "$m" = "message" ]; then
                    telegram_configure_heartbeat "true" 7 "$m"
                else
                    ui_warning "Mode must be 'compact' or 'message'"
                fi
                ui_pause
                ;;
            4)
                telegram_configure_heartbeat "false" 7 "compact"
                ui_pause
                ;;
            0|[qQ]*)
                break
                ;;
        esac
    done
}

# Submenu: Telegram Bot Remote Control
handle_telegram_submenu() {
    while true; do
        clear 2>/dev/null || echo
        ui_header
        echo -e "${C_BCYAN}=== CyberVPS Telegram Remote Administration & Heartbeat ===${C_RESET}"
        echo
        telegram_status
        echo
        echo -e "  ${C_BWHITE}[1]${C_RESET} Test Bot Connection (getMe)"
        echo -e "  ${C_BWHITE}[2]${C_RESET} Start Telegram Bot Service"
        echo -e "  ${C_BWHITE}[3]${C_RESET} Stop Telegram Bot Service"
        echo -e "  ${C_BWHITE}[4]${C_RESET} Configure Heartbeat Settings"
        echo -e "  ${C_BWHITE}[5]${C_RESET} Set Authorized Admin User IDs"
        echo -e "  ${C_BWHITE}[6]${C_RESET} Store / Update Bot Token (0600)"
        echo -e "  ${C_BWHITE}[7]${C_RESET} View Telegram Logs"
        echo -e "  ${C_BWHITE}[8]${C_RESET} Run Telegram Subsystem Doctor"
        echo -e "  ${C_BWHITE}[0]${C_RESET} Return to Main Menu"
        echo
        local choice=""
        read -rp "Telegram Action: " choice || break
        case "$choice" in
            1)
                telegram_test
                ui_pause
                ;;
            2)
                telegram_start
                ui_pause
                ;;
            3)
                telegram_stop
                ui_pause
                ;;
            4)
                handle_heartbeat_settings_menu
                ;;
            5)
                local uids=""
                read -rp "Enter Telegram Admin User ID(s) separated by space: " uids
                if [ -n "$uids" ]; then
                    telegram_set_users "$uids"
                fi
                ui_pause
                ;;
            6)
                local tok=""
                read -s -rp "Enter Telegram Bot Token: " tok
                echo
                if [ -n "$tok" ]; then
                    telegram_set_token "$tok"
                fi
                ui_pause
                ;;
            7)
                telegram_logs 30
                ui_pause
                ;;
            8)
                telegram_doctor
                ui_pause
                ;;
            0|[qQ]*)
                break
                ;;
        esac
    done
}

# Submenu: Cloudflare Tunnels
handle_tunnels_submenu() {
    while true; do
        clear 2>/dev/null || echo
        ui_header
        echo -e "${C_BCYAN}=== CyberVPS Remote Cloudflare Tunnels ===${C_RESET}"
        echo
        tunnel_status
        echo
        echo -e "  ${C_BWHITE}[1]${C_RESET} Start Quick Tunnel (trycloudflare)"
        echo -e "  ${C_BWHITE}[2]${C_RESET} Stop Active Tunnel"
        echo -e "  ${C_BWHITE}[3]${C_RESET} View Public Tunnel URL"
        echo -e "  ${C_BWHITE}[4]${C_RESET} View Tunnel Logs"
        echo -e "  ${C_BWHITE}[0]${C_RESET} Return to Main Menu"
        echo
        local choice=""
        read -rp "Tunnel Action: " choice || break
        case "$choice" in
            1)
                local tport=""
                read -rp "Target local port to tunnel (default 7681): " tport
                [ -z "$tport" ] && tport=7681
                tunnel_quick_start "$tport"
                ui_pause
                ;;
            2)
                tunnel_stop
                ui_pause
                ;;
            3)
                echo "Current Tunnel Public URL:"
                tunnel_url
                ui_pause
                ;;
            4)
                tunnel_logs webterm 30
                ui_pause
                ;;
            0|[qQ]*)
                break
                ;;
        esac
    done
}

# Submenu: Background Jobs & Watchdog
handle_jobs_submenu() {
    while true; do
        clear 2>/dev/null || echo
        ui_header
        echo -e "${C_BCYAN}=== CyberVPS Persistent Background Tasks & Watchdog ===${C_RESET}"
        echo
        job_list
        echo
        echo -e "  ${C_BWHITE}[1]${C_RESET} List Background Jobs"
        echo -e "  ${C_BWHITE}[2]${C_RESET} Launch New Background Job"
        echo -e "  ${C_BWHITE}[3]${C_RESET} View Job Logs"
        echo -e "  ${C_BWHITE}[4]${C_RESET} Cancel Running Job"
        echo -e "  ${C_BWHITE}[5]${C_RESET} Run Service Watchdog Check"
        echo -e "  ${C_BWHITE}[0]${C_RESET} Return to Main Menu"
        echo
        local choice=""
        read -rp "Job Action: " choice || break
        case "$choice" in
            1)
                clear 2>/dev/null || echo
                job_list
                ui_pause
                ;;
            2)
                local jname="" jcmd=""
                read -rp "Job Name: " jname
                read -rp "Command to run in background: " jcmd
                if [ -n "$jname" ] && [ -n "$jcmd" ]; then
                    job_run "$jname" "$jcmd"
                fi
                ui_pause
                ;;
            3)
                local jname=""
                read -rp "Job Name to view logs: " jname
                [ -n "$jname" ] && job_logs "$jname" 30
                ui_pause
                ;;
            4)
                local jname=""
                read -rp "Job Name to cancel: " jname
                [ -n "$jname" ] && job_cancel "$jname"
                ui_pause
                ;;
            5)
                job_watchdog
                ui_pause
                ;;
            0|[qQ]*)
                break
                ;;
        esac
    done
}

handle_databases_menu() {
    clear 2>/dev/null || echo
    ui_header
    echo -e "${C_BCYAN}=== CyberVPS Database Management (Redis / SQLite) ===${C_RESET}\n"
    local redis_st="Not Installed"
    if command -v redis-server >/dev/null 2>&1; then
        redis_st="Installed (Stopped)"
        is_service_running "redis" && redis_st="Running"
    fi
    local sqlite_st="Not Installed"
    command -v sqlite3 >/dev/null 2>&1 && sqlite_st="Available ($(sqlite3 --version 2>&1 | awk '{print $1}'))"

    ui_kv "Redis Engine" "$redis_st"
    ui_kv "SQLite3 CLI" "$sqlite_st"
    echo
    echo -e "  ${C_BWHITE}[1]${C_RESET} Start Redis Service"
    echo -e "  ${C_BWHITE}[2]${C_RESET} Stop Redis Service"
    echo -e "  ${C_BWHITE}[3]${C_RESET} Redis Status & Ping"
    echo -e "  ${C_BWHITE}[0]${C_RESET} Back to Main Menu"
    echo
    local db_choice=""
    read -rp "Database Action: " db_choice || return 0
    case "$db_choice" in
        1) service_start redis; ui_pause ;;
        2) service_stop redis; ui_pause ;;
        3) service_status redis; ui_pause ;;
        *) ;;
    esac
}

handle_desktop_menu() {
    clear 2>/dev/null || echo
    ui_header
    echo -e "${C_BCYAN}=== CyberVPS Desktop & GUI Environment ===${C_RESET}\n"
    # shellcheck source=lib/desktop.sh
    source "$CYBERVPS_DIR/lib/desktop.sh" 2>/dev/null || true
    desktop_cli doctor 2>&1 || true
    echo
    echo -e "  ${C_BWHITE}[1]${C_RESET} View Connection Instructions"
    echo -e "  ${C_BWHITE}[2]${C_RESET} Install Desktop (Requires Root)"
    echo -e "  ${C_BWHITE}[3]${C_RESET} Start Desktop Service"
    echo -e "  ${C_BWHITE}[4]${C_RESET} Stop Desktop Service"
    echo -e "  ${C_BWHITE}[0]${C_RESET} Back to Main Menu"
    echo
    local desk_choice=""
    read -rp "Desktop Action: " desk_choice || return 0
    case "$desk_choice" in
        1) desktop_cli connection; ui_pause ;;
        2) desktop_cli install; ui_pause ;;
        3) desktop_cli start; ui_pause ;;
        4) desktop_cli stop; ui_pause ;;
        *) ;;
    esac
}

handle_auto_menu() {
    ui_auto_install_screen
    local lvl=""
    read -r -p "Enter Choice [1-4, Default: 4]: " lvl || return 0
    case "$lvl" in
        0|[qQ]*) return 0 ;;
        1) cyber_auto_install 1 ;;
        2) cyber_auto_install 2 ;;
        3) cyber_auto_install 3 ;;
        4|''|*) cyber_auto_install 4 ;;
    esac
    ui_pause
}

handle_restore_menu() {
    clear 2>/dev/null || echo
    ui_header
    echo -e "${C_BCYAN}=== CyberVPS Backup Restore ===${C_RESET}\n"

    local found_backups=()
    local search_dirs=("$CYBERVPS_DIR/downloads" "$CYBER_HOME/downloads" "$CYBER_HOME/backups")
    for d in "${search_dirs[@]}"; do
        [ -d "$d" ] || continue
        for b in "$d"/cybervps-backup-*.tar.*; do
            if [ -f "$b" ]; then
                found_backups+=("$b")
            fi
        done
    done

    if [ "${#found_backups[@]}" -eq 0 ]; then
        echo -e "${C_TEXT_MUTED}No backup archives found in downloads/ or backups/.${C_RESET}\n"
        echo -e "  ${C_BWHITE}[P]${C_RESET} Provide custom path to backup archive"
        echo -e "  ${C_BWHITE}[0]${C_RESET} Return to Main Menu"
        echo
        local res_choice=""
        read -rp "Restore Selection: " res_choice || return 0
        case "$res_choice" in
            [pP]*)
                local custom_path=""
                read -rp "Enter full path to backup file: " custom_path
                if [ -n "$custom_path" ] && [ -f "$custom_path" ]; then
                    run_menu_action "Restore Backup" "$CYBERVPS_DIR/restore.sh" "restore" --archive "$custom_path"
                else
                    ui_warning "File does not exist: '$custom_path'"
                    ui_pause
                fi
                ;;
            *)
                return 0
                ;;
        esac
    else
        echo -e "${C_BWHITE}Discovered Backup Archives:${C_RESET}"
        local idx=1
        for b in "${found_backups[@]}"; do
            local bsize
            bsize="$(du -h "$b" 2>/dev/null | awk '{print $1}')"
            echo -e "  ${C_BWHITE}[${idx}]${C_RESET} $(basename "$b") ${C_TEXT_MUTED}(${bsize} in $(dirname "$b"))${C_RESET}"
            idx=$((idx + 1))
        done
        echo -e "  ${C_BWHITE}[P]${C_RESET} Provide custom path"
        echo -e "  ${C_BWHITE}[0]${C_RESET} Return to Main Menu"
        echo
        local sel=""
        read -rp "Select archive to restore [1-${#found_backups[@]}]: " sel || return 0
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#found_backups[@]}" ]; then
            local chosen="${found_backups[$((sel - 1))]}"
            run_menu_action "Restore Backup" "$CYBERVPS_DIR/restore.sh" "restore" --archive "$chosen"
        elif [[ "$sel" =~ ^[pP] ]]; then
            local custom_path=""
            read -rp "Enter full path to backup file: " custom_path
            if [ -n "$custom_path" ] && [ -f "$custom_path" ]; then
                run_menu_action "Restore Backup" "$CYBERVPS_DIR/restore.sh" "restore" --archive "$custom_path"
            else
                ui_warning "File does not exist: '$custom_path'"
                ui_pause
            fi
        fi
    fi
}

handle_virtual_shell() {
    detect_environment
    if [ "${CYBER_PRIVILEGE_MODE:-ROOTLESS}" = "ROOT" ] || [ "${CYBER_PRIVILEGE_MODE:-ROOTLESS}" = "CONTAINER_ROOT" ] || [ "${CYBER_IS_ROOT:-false}" = true ]; then
        echo -e "\n${C_PRIMARY}${C_BOLD}CyberVPS Host Shell (Native Root)${C_RESET}"
        echo -e "${C_TEXT_MUTED}Active Mode: ${C_TEXT}${CYBER_PRIVILEGE_MODE}${C_TEXT_MUTED} | User: ${C_TEXT}${CYBER_USER} (UID ${CYBER_UID})${C_RESET}"
        echo -e "${C_TEXT_MUTED}Type ${C_PRIMARY}'exit'${C_TEXT_MUTED} to return to CyberVPS dashboard.\n${C_RESET}"
        CYBERVPS_HOST_SHELL=1 "${SHELL:-/bin/bash}" -l
        return 0
    fi
    cyber_guest_shell "$@"
}

# Render Dashboard (CYBER DARK Modern UI)
show_dashboard() {
    clear 2>/dev/null || echo
    ui_header
    ui_render_system_card
    ui_render_runtime_cards
    ui_dashboard_menu_grid
    ui_footer
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
                handle_restore_menu
                ;;
            2)
                run_menu_action "Install / Rebuild" "$CYBERVPS_DIR/fresh-install.sh" "fresh-install"
                ;;
            3)
                run_menu_action "Migrate Backup" "$CYBERVPS_DIR/migrate.sh" "migration"
                ;;
            4)
                handle_databases_menu
                ;;
            5)
                handle_telegram_submenu
                ;;
            6)
                handle_desktop_menu
                ;;
            7)
                handle_sessions_submenu
                ;;
            8)
                handle_tunnels_submenu
                ;;
            9)
                run_menu_action "Create Backup" "$CYBERVPS_DIR/backup-now.sh" "backup"
                ;;
            10|[cC]*)
                handle_cyberroot_menu
                ;;
            11)
                # shellcheck source=lib/cybervm.sh
                source "$CYBERVPS_DIR/lib/cybervm.sh" 2>/dev/null || true
                cybervm_cli status 2>/dev/null || echo "CyberVM: MicroVM Platform ready"
                ui_pause
                ;;
            12)
                # shellcheck source=lib/containers.sh
                source "$CYBERVPS_DIR/lib/containers.sh" 2>/dev/null || true
                containers_cli status 2>/dev/null || echo "Containers: Rootless Docker/Podman engine ready"
                ui_pause
                ;;
            13)
                handle_jobs_submenu
                ;;
            14)
                handle_remote_access_menu
                ;;
            15)
                handle_fleet_submenu
                ;;
            16)
                python3 "$CYBERVPS_DIR/scripts/security_audit.py" "$CYBERVPS_DIR" 2>/dev/null || echo "Security audit: Clean"
                ui_pause
                ;;
            17)
                handle_config_menu
                ;;
            18)
                run_menu_action "VPS Health Verification" "$CYBERVPS_DIR/verify.sh" "verify"
                ;;
            [aA]*)
                handle_auto_menu
                ;;
            [sS]*)
                handle_virtual_shell
                ;;
            [tT]*)
                handle_transfer_submenu
                ;;
            [dD]*)
                handle_diagnostics_menu
                ;;
            [rR]*)
                run_self_repair
                ;;
            [lL]*)
                ui_view_log "${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/logs/cybervps.log"
                ;;
            [uU]*)
                python3 "$CYBERVPS_DIR/scripts/operations.py" update 2>/dev/null || echo "CyberVPS is up to date."
                ui_pause
                ;;
            \?|[hH]*)
                echo -e "\n${C_PRIMARY}=== CyberVPS Navigation & Shortcuts ===${C_RESET}"
                echo "  [1-6]   Hosting & Application Management"
                echo "  [7-12]  System, Terminals, Virtual Root & Containers"
                echo "  [13-18] Fleet, Security, Settings & Diagnostics"
                echo "  [A]     Zero-Touch Auto Provisioning"
                echo "  [S]     PRoot Virtual Root Shell"
                echo "  [D]     Diagnostics / Doctor"
                echo "  [R]     Self-Repair"
                echo "  [L]     View Logs"
                echo "  [U]     Update CyberVPS"
                echo "  [0]     Exit"
                ui_pause
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
elif [ "${1:-}" = "tunnel" ]; then
    shift
    handle_tunnel_cli "$@"
    exit $?
elif [ "${1:-}" = "telegram" ]; then
    shift
    handle_telegram_cli "$@"
    exit $?
elif [ "${1:-}" = "job" ]; then
    shift
    handle_job_cli "$@"
    exit $?
elif [ "${1:-}" = "connect" ]; then
    shift
    cybervps_connect_cli "$@"
    exit $?
elif [ "${1:-}" = "public" ]; then
    shift
    cybervps_public_cli "$@"
    exit $?
elif [ "${1:-}" = "guest" ]; then
    shift
    cyber_guest_cli "$@"
    exit $?
elif [ "${1:-}" = "fleet" ]; then
    shift
    cybervps_fleet_cli "$@"
    exit $?
elif [ "${1:-}" = "transfer" ]; then
    shift
    cybervps_transfer_cli "$@"
    exit $?
elif [ "${1:-}" = "store" ]; then
    shift
    cybervps_store_cli "$@"
    exit $?
elif [ "$#" -gt 0 ] && [ "${1:-}" != "--menu" ]; then
    cyber_control_cli "$@"
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
    echo "  cybervps tunnel <command>"
    echo "  cybervps telegram <command>"
    echo "  cybervps job <command>"
    exit 0
fi
