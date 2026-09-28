#!/usr/bin/env bash
# lib/persistence.sh — CyberVPS Startup & Recovery Engine
# Detects, configures, and manages multi-tier rootless persistence:
# Tier 1: True Boot Autostart (systemd --user with lingering, or cron @reboot)
# Tier 2: Login-Triggered Recovery (idempotent marked shell profile block)
# Tier 3: Session Persistence (tmux / screen / nohup surviving SSH disconnect)
# Clearly labels each mode without claiming boot persistence when only login recovery exists.

[ -n "${_CYBERVPS_PERSISTENCE_SH_LOADED:-}" ] && return 0
_CYBERVPS_PERSISTENCE_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=lib/services.sh
source "$LIB_DIR/services.sh"
# shellcheck source=lib/sessions.sh
source "$LIB_DIR/sessions.sh"

PERSISTENCE_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/persistence"
PERSISTENCE_LOGS_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/logs"

persistence_init_dirs() {
    PERSISTENCE_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/persistence"
    PERSISTENCE_LOGS_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/logs"
    ensure_directory "$PERSISTENCE_STATE_DIR" 0700
    ensure_directory "$PERSISTENCE_LOGS_DIR" 0755
}

# Check if systemd --user is functional without root
can_use_user_systemd() {
    have_command systemctl && systemctl --user list-units >/dev/null 2>&1
}

# Check if loginctl lingering is enabled for the current user
is_user_lingering_active() {
    if have_command loginctl; then
        local user_name="${USER:-$(whoami)}"
        loginctl show-user "$user_name" 2>/dev/null | grep -qi "Linger=yes" && return 0
    fi
    # Also check /var/lib/systemd/linger/$USER if readable
    if [ -f "/var/lib/systemd/linger/${USER:-$(whoami)}" ]; then
        return 0
    fi
    return 1
}

# Check if cron @reboot is supported and available
can_use_user_cron() {
    if have_command crontab; then
        # Check if crontab can be read or edited without root
        crontab -l >/dev/null 2>&1 || [ $? -eq 1 ] # exit 1 usually means no crontab for user, which is ok
    else
        return 1
    fi
}

# Detect persistence capabilities across tiers
persistence_detect_modes() {
    local boot_mode="UNSUPPORTED"
    local login_mode="SUPPORTED"
    local session_mode="SUPPORTED"
    local best_tier="LOGIN-TRIGGERED"

    # 1. Systemd user linger
    if can_use_user_systemd; then
        if is_user_lingering_active; then
            boot_mode="AVAILABLE (systemd --user with lingering)"
            best_tier="TRUE BOOT AUTOSTART"
        else
            boot_mode="PARTIAL (systemd --user present, but user lingering not enabled by host)"
        fi
    elif can_use_user_cron; then
        boot_mode="AVAILABLE (cron @reboot)"
        best_tier="TRUE BOOT AUTOSTART"
    fi

    # 2. Session persistence
    local session_backend
    session_backend="$(session_get_backend)"
    session_mode="AVAILABLE ($session_backend)"

    echo "=== CyberVPS Persistence Capability Matrix ==="
    echo "  • True Boot Autostart  : $boot_mode"
    echo "  • Login Recovery       : $login_mode (~/.profile / ~/.bashrc)"
    echo "  • Session Persistence  : $session_mode"
    echo "  • Recommended Tier     : $best_tier"
    echo
}

# Setup persistence at the highest available tier
persistence_setup() {
    persistence_init_dirs
    local helper_bin="${HOME}/bin/cybervps-start"
    ensure_directory "$(dirname "$helper_bin")"
    install_service_cli_helpers >/dev/null 2>&1 || true

    # Try setting up login recovery as baseline
    setup_login_recovery

    # Check if cron @reboot is usable
    if can_use_user_cron; then
        local current_cron
        current_cron="$(crontab -l 2>/dev/null || true)"
        if ! echo "$current_cron" | grep -q "cybervps-start"; then
            local new_cron
            new_cron="$(printf "%s\n@reboot %s --background >/dev/null 2>&1\n" "$current_cron" "$helper_bin" | sed '/^$/N;/^\n$/D')"
            echo "$new_cron" | crontab - 2>/dev/null || true
            log_ok "Registered cron @reboot hook for CyberVPS service autostart."
        fi
    fi

    log_ok "CyberVPS recovery and persistence engine configured."
}

# Disable all persistence hooks
persistence_disable() {
    persistence_init_dirs
    disable_login_recovery

    if have_command crontab; then
        local current_cron
        current_cron="$(crontab -l 2>/dev/null || true)"
        if echo "$current_cron" | grep -q "cybervps-start"; then
            local clean_cron
            clean_cron="$(echo "$current_cron" | grep -v "cybervps-start" || true)"
            if [ -n "$clean_cron" ]; then
                echo "$clean_cron" | crontab - 2>/dev/null || true
            else
                crontab -r 2>/dev/null || true
            fi
            log_ok "Removed cron @reboot hook."
        fi
    fi

    log_ok "CyberVPS persistence hooks disabled."
}

# Run recovery on login or startup
persistence_recover() {
    persistence_init_dirs
    local log_file="$PERSISTENCE_LOGS_DIR/recovery.log"
    local now
    now="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date)"

    echo "[$now] Starting CyberVPS service recovery..." >> "$log_file"

    local restored_count=0
    service_init_dirs
    for cfg in "$SERVICES_CONFIG_DIR"/*.json; do
        [ -f "$cfg" ] || continue
        local s_name s_enabled
        s_name="$(basename "$cfg" .json)"
        s_enabled="$(_service_get_field "$cfg" "enabled" "true")"

        if [ "$s_enabled" = "true" ]; then
            if ! is_service_running "$s_name"; then
                service_start "$s_name" >> "$log_file" 2>&1 || true
                restored_count=$((restored_count + 1))
            fi
        fi
    done

    echo "[$now] CyberVPS recovery completed: restored $restored_count service(s)." >> "$log_file"
    log_ok "CyberVPS recovery completed: restored $restored_count service(s)."
}

# CLI dispatcher
handle_persistence_cli() {
    local action="${1:-status}"
    shift || true

    case "$action" in
        detect|matrix)
            persistence_detect_modes
            ;;
        setup|enable)
            persistence_setup
            ;;
        disable|remove)
            persistence_disable
            ;;
        recover|start)
            persistence_recover
            ;;
        status)
            persistence_detect_modes
            ;;
        help|--help|-h)
            echo "CyberVPS Startup & Recovery Engine"
            echo "Usage: cybervps persistence <command>"
            echo
            echo "Commands:"
            echo "  status / detect   Display persistence capabilities and active mode"
            echo "  setup             Configure highest available persistence tier"
            echo "  disable           Disable startup and recovery hooks"
            echo "  recover           Execute recovery of enabled services"
            ;;
        *)
            log_error "Unknown persistence command: '$action'. Try: cybervps persistence help"
            return 1
            ;;
    esac
}
