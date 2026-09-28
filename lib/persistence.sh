#!/usr/bin/env bash
# lib/persistence.sh — CyberVPS Startup & Recovery Engine
# Detects and configures current-user recovery without provider durability claims:
# Tier 1: Boot capability (operational systemd user manager plus lingering)
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
    cyber_systemd_user_available
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
    have_command crontab || return 1
    local output rc=0
    local LC_ALL=C
    output="$(crontab -l 2>&1)" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    [ "$rc" -eq 1 ] || return 1
    case "$output" in
        *'no crontab for'*) return 0 ;;
        *) return 1 ;;
    esac
}

persistence_cron_running() {
    have_command pgrep && { pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1; }
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
            boot_mode="AVAILABLE (systemd --user with lingering; enabled units required)"
            best_tier="BOOT AUTOSTART CAPABLE"
        else
            boot_mode="PARTIAL (systemd --user present, but user lingering not enabled by host)"
        fi
    elif can_use_user_cron; then
        if persistence_cron_running; then
            boot_mode="PARTIAL (cron running; @reboot support and provider restart behavior must be verified)"
        else
            boot_mode="UNVERIFIED (crontab writable; cron daemon not confirmed)"
        fi
    fi

    # 2. Session persistence
    local session_backend
    session_backend="$(session_get_backend)"
    session_mode="AVAILABLE ($session_backend; only while the node remains running)"
    [ "$session_backend" = none ] && session_mode="UNAVAILABLE"

    echo "=== CyberVPS Persistence Capability Matrix ==="
    echo "  • Boot Autostart       : $boot_mode"
    echo "  • Login Recovery       : $login_mode (~/.profile / ~/.bashrc)"
    echo "  • Session Persistence  : $session_mode"
    echo "  • Recommended Tier     : $best_tier"
    echo "  • Provider Persistence : UNKNOWN (provider stop/delete overrides local recovery)"
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

    # Register only after verifying crontab access; report failures honestly.
    if can_use_user_cron; then
        local current_cron escaped_helper
        current_cron="$(crontab -l 2>/dev/null || true)"
        if ! printf '%s\n' "$current_cron" | grep -q '# CYBERVPS MANAGED RECOVERY$'; then
            if [[ "$helper_bin" = *$'\n'* || "$helper_bin" = *'%'* ]]; then
                log_warn "Cron recovery skipped: HOME contains characters unsupported by crontab."
            else
                printf -v escaped_helper '%q' "$helper_bin"
                if printf '%s\n@reboot %s --background >/dev/null 2>&1 # CYBERVPS MANAGED RECOVERY\n' "$current_cron" "$escaped_helper" | crontab -; then
                    log_ok "Registered cron recovery hook; provider restart support remains unverified."
                else
                    log_error "Could not register cron recovery hook; login recovery remains configured."
                    return 1
                fi
            fi
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
        if echo "$current_cron" | grep -q '# CYBERVPS MANAGED RECOVERY$'; then
            local clean_cron
            clean_cron="$(echo "$current_cron" | grep -v '# CYBERVPS MANAGED RECOVERY$' || true)"
            if [ -n "$clean_cron" ]; then
                echo "$clean_cron" | crontab - || return 1
            else
                crontab -r || return 1
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

    local restored_count=0 failed_count=0
    service_init_dirs
    for cfg in "$SERVICES_CONFIG_DIR"/*.json; do
        [ -f "$cfg" ] || continue
        local s_name s_enabled
        s_name="$(basename "$cfg" .json)"
        s_enabled="$(_service_get_field "$cfg" "enabled" "true")"

        if [ "$s_enabled" = "true" ]; then
            if ! is_service_running "$s_name"; then
                if service_start "$s_name" >> "$log_file" 2>&1; then
                    restored_count=$((restored_count + 1))
                else
                    failed_count=$((failed_count + 1))
                    log_warn "Service recovery failed for $s_name; see $log_file"
                fi
            fi
        fi
    done

    echo "[$now] CyberVPS recovery completed: restored $restored_count service(s)." >> "$log_file"
    if [ "$failed_count" -gt 0 ]; then
        log_error "Recovery incomplete: $restored_count restored, $failed_count failed. Log: $log_file"
        return 1
    fi
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
        setup|install|enable)
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
