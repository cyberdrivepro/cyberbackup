#!/usr/bin/env bash
# lib/telegram.sh — CyberVPS Telegram Remote Administration & Heartbeat Subsystem
# Manages bot registration, authorized admin allowlists, heartbeat intervals,
# and background execution as a persistent CyberVPS service.

[ -n "${_CYBERVPS_TELEGRAM_SH_LOADED:-}" ] && return 0
_CYBERVPS_TELEGRAM_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=lib/services.sh
source "$LIB_DIR/services.sh"

TG_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cybervps/telegram"
TG_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/telegram"
TG_TOKEN_FILE="$TG_CONFIG_DIR/bot_token"
TG_CONFIG_FILE="$TG_CONFIG_DIR/config.json"
TG_AGENT_SCRIPT="$LIB_DIR/../agent/cybervps_telegram.py"

telegram_init_dirs() {
    TG_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cybervps/telegram"
    TG_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/telegram"
    TG_TOKEN_FILE="$TG_CONFIG_DIR/bot_token"
    TG_CONFIG_FILE="$TG_CONFIG_DIR/config.json"

    ensure_directory "$TG_CONFIG_DIR" 0700
    ensure_directory "$TG_STATE_DIR" 0700
}

# Check if bot token is configured
telegram_has_token() {
    telegram_init_dirs
    [ -f "$TG_TOKEN_FILE" ] && [ -s "$TG_TOKEN_FILE" ]
}

# Read bot token safely
telegram_get_token() {
    telegram_init_dirs
    if [ -f "$TG_TOKEN_FILE" ]; then
        head -n1 "$TG_TOKEN_FILE" | tr -d '\r\n '
    fi
}

# Set bot token with 0600 permissions
telegram_set_token() {
    local token="$1"
    telegram_init_dirs
    printf '%s\n' "$token" > "$TG_TOKEN_FILE"
    chmod 0600 "$TG_TOKEN_FILE" 2>/dev/null || true
    log_ok "Telegram bot token saved securely in $TG_TOKEN_FILE (0600)."
}

# Start Telegram bot as a persistent CyberVPS service
telegram_start() {
    telegram_init_dirs

    if ! telegram_has_token; then
        log_error "Telegram bot token not found. Set it with: cybervps telegram set-token <token>"
        return 1
    fi

    if is_service_running "cybervps-telegram"; then
        log_info "CyberVPS Telegram service is already running."
        telegram_status
        return 0
    fi

    log_info "Registering CyberVPS Telegram Agent as a persistent service..."
    service_add "cybervps-telegram" \
        --cmd "python3 '$TG_AGENT_SCRIPT'" \
        --cwd "$HOME" \
        --restart "always" \
        --health-type "process"

    service_start "cybervps-telegram"
    log_ok "CyberVPS Telegram Agent started as persistent service."
}

# Stop Telegram bot
telegram_stop() {
    telegram_init_dirs
    service_stop "cybervps-telegram"
    log_ok "CyberVPS Telegram Agent stopped."
}

# Restart Telegram bot
telegram_restart() {
    telegram_init_dirs
    service_restart "cybervps-telegram"
}

# Show status of Telegram bot and heartbeat
telegram_status() {
    telegram_init_dirs
    echo "=== CyberVPS Telegram Remote Control Status ==="

    if is_service_running "cybervps-telegram"; then
        echo "Bot Service   : RUNNING (persistent)"
    else
        echo "Bot Service   : STOPPED"
    fi

    if telegram_has_token; then
        echo "Bot Token     : CONFIGURED (0600 stored outside Git)"
    else
        echo "Bot Token     : NOT CONFIGURED"
    fi

    if [ -f "$TG_CONFIG_FILE" ]; then
        local admins hb_on hb_interval hb_mode
        admins="$(grep -o '"admin_user_ids": *\[[^]]*\]' "$TG_CONFIG_FILE" 2>/dev/null || echo "[]")"
        hb_on="$(grep -o '"heartbeat_enabled": *[a-zA-Z]*' "$TG_CONFIG_FILE" 2>/dev/null | awk '{print $2}' || echo "true")"
        hb_interval="$(grep -o '"heartbeat_interval_minutes": *[0-9]*' "$TG_CONFIG_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "7")"
        hb_mode="$(grep -o '"heartbeat_mode": *"[^"]*"' "$TG_CONFIG_FILE" 2>/dev/null | cut -d'"' -f4 || echo "compact")"

        echo "Admins        : $admins"
        echo "Heartbeat     : $hb_on (Interval: ${hb_interval}m, Mode: ${hb_mode})"
    else
        echo "Heartbeat     : ENABLED (Default: 7m, compact)"
    fi

    local state_f="$TG_STATE_DIR/state.json"
    if [ -f "$state_f" ]; then
        local last_s
        last_s="$(grep -o '"last_heartbeat_success": *"[^"]*"' "$state_f" 2>/dev/null | cut -d'"' -f4 || echo "None")"
        echo "Last Heartbeat: $last_s"
    fi
}

# Test connection to Telegram API
telegram_test() {
    telegram_init_dirs
    local token
    token="$(telegram_get_token)"

    if [ -z "$token" ]; then
        log_error "Telegram bot token is not configured."
        return 1
    fi

    log_info "Testing Telegram API connectivity via getMe..."
    local res
    if have_command curl; then
        res="$(curl -s -m 10 "https://api.telegram.org/bot${token}/getMe")"
    else
        res="$(python3 -c "import urllib.request; print(urllib.request.urlopen('https://api.telegram.org/bot${token}/getMe', timeout=10).read().decode())" 2>/dev/null || true)"
    fi

    if echo "$res" | grep -q '"ok":true'; then
        local bot_name
        bot_name="$(echo "$res" | grep -o '"username":"[^"]*"' | cut -d'"' -f4)"
        log_ok "Connected successfully to @${bot_name}!"
        echo "✅ CyberVPS Telegram connection test successful."
        return 0
    else
        log_error "Telegram connection failed: $res"
        return 1
    fi
}

# View Telegram logs
telegram_logs() {
    service_logs "cybervps-telegram" "$@"
}

# CLI Dispatcher
handle_telegram_cli() {
    local action="${1:-status}"
    shift || true

    case "$action" in
        start)
            telegram_start
            ;;
        stop)
            telegram_stop
            ;;
        restart)
            telegram_restart
            ;;
        status)
            telegram_status
            ;;
        test)
            telegram_test
            ;;
        logs)
            telegram_logs "$@"
            ;;
        set-token)
            if [ $# -lt 1 ]; then
                echo "Usage: cybervps telegram set-token <token>"
                return 1
            fi
            telegram_set_token "$1"
            ;;
        help|--help|-h)
            echo "CyberVPS Telegram Remote Administration"
            echo "Usage: cybervps telegram <command> [args...]"
            echo
            echo "Commands:"
            echo "  start       Start Telegram bot daemon as persistent CyberVPS service"
            echo "  stop        Stop Telegram bot daemon"
            echo "  restart     Restart Telegram bot daemon"
            echo "  status      Display bot state, authorized admins, and heartbeat info"
            echo "  test        Test connectivity to Telegram API (getMe)"
            echo "  logs        View Telegram service logs"
            echo "  set-token   Store bot token securely outside git (0600)"
            ;;
        *)
            log_error "Unknown telegram command: '$action'. Try: cybervps telegram help"
            return 1
            ;;
    esac
}
