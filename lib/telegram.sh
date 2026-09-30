#!/usr/bin/env bash
# lib/telegram.sh — CyberVPS Telegram Remote Administration & Heartbeat Subsystem
# Manages bot registration, authorized admin allowlists, heartbeat intervals,
# API validation, diagnostics, and background execution as a persistent CyberVPS service.

[ -n "${_CYBERVPS_TELEGRAM_SH_LOADED:-}" ] && return 0
_CYBERVPS_TELEGRAM_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=lib/ui.sh
source "$LIB_DIR/ui.sh"
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

# Check if bot token is configured and non-empty
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

# Validate token string structure without sending requests
telegram_validate_token_format() {
    local token="${1:-}"
    [[ "$token" =~ ^[0-9]{7,14}:[a-zA-Z0-9_-]{30,}$ ]]
}

# Set bot token with 0600 permissions
telegram_set_token() {
    local token="$1"
    telegram_init_dirs
    if ! telegram_validate_token_format "$token"; then
        log_warn "Token does not match standard Telegram Bot token pattern (e.g. 123456789:ABCdef...). Saving anyway."
    fi
    printf '%s\n' "$token" > "$TG_TOKEN_FILE"
    chmod 0600 "$TG_TOKEN_FILE" 2>/dev/null || true
    # Clear stale cached status
    rm -f "$TG_STATE_DIR/api_status.json" 2>/dev/null || true
    log_ok "Telegram bot token saved securely in $TG_TOKEN_FILE (0600)."
}

# Redact token from any string/output
_telegram_redact() {
    local str="${1:-}"
    local token
    token="$(telegram_get_token || true)"
    if [ -n "$token" ]; then
        str="${str//"$token"/<REDACTED_TOKEN>}"
    fi
    printf '%s\n' "$str"
}

# Query Telegram getMe API with full error classification
# Never prints or logs the token. Returns JSON on stdout.
telegram_query_getme() {
    local token="${1:-}"
    [ -z "$token" ] && token="$(telegram_get_token || true)"

    if [ -z "$token" ]; then
        printf '{"status":"MISSING_TOKEN","error":"Bot token not configured"}\n'
        return 1
    fi

    if ! telegram_validate_token_format "$token"; then
        printf '{"status":"INVALID_FORMAT","error":"Bot token format is invalid"}\n'
        return 1
    fi

    local status="UNKNOWN" error_desc="" bot_username="" http_code=0
    local raw_json="" stderr_tmp curl_rc=0
    stderr_tmp="$(mktemp)"

    if have_command curl; then
        local raw_res
        raw_res="$(curl --silent --show-error --connect-timeout 10 --max-time 20 \
            -w "\nHTTP_CODE:%{http_code}" \
            "https://api.telegram.org/bot${token}/getMe" 2>"$stderr_tmp")" || curl_rc=$?

        http_code="$(echo "$raw_res" | grep -o 'HTTP_CODE:[0-9]*' | cut -d: -f2 || echo 0)"
        raw_json="$(echo "$raw_res" | sed '/HTTP_CODE:/d')"
    elif have_command python3; then
        local py_res
        py_res="$(python3 - <<PY 2>"$stderr_tmp"
import urllib.request, urllib.error, json, sys
token = "$token"
url = f"https://api.telegram.org/bot{token}/getMe"
try:
    with urllib.request.urlopen(url, timeout=15) as resp:
        body = resp.read().decode()
        print(f"HTTP_CODE:{resp.status}")
        print(body)
except urllib.error.HTTPError as e:
    body = e.read().decode() if e.fp else ""
    print(f"HTTP_CODE:{e.code}")
    print(body)
except urllib.error.URLError as e:
    sys.stderr.write(str(e.reason))
    sys.exit(6)
except Exception as e:
    sys.stderr.write(str(e))
    sys.exit(1)
PY
)" || curl_rc=$?
        http_code="$(echo "$py_res" | grep -o 'HTTP_CODE:[0-9]*' | cut -d: -f2 || echo 0)"
        raw_json="$(echo "$py_res" | sed '/HTTP_CODE:/d')"
    else
        rm -f "$stderr_tmp"
        printf '{"status":"NO_CLIENT","error":"Neither curl nor python3 is available"}\n'
        return 1
    fi

    local err_text
    err_text="$(cat "$stderr_tmp" 2>/dev/null || true)"
    rm -f "$stderr_tmp"
    err_text="$(_telegram_redact "$err_text")"

    # Classify result
    if [ "$http_code" -eq 200 ] && echo "$raw_json" | grep -q '"ok":true'; then
        status="CONNECTED"
        bot_username="$(echo "$raw_json" | grep -o '"username":"[^"]*"' | head -n1 | cut -d'"' -f4 || true)"
    elif [ "$http_code" -eq 401 ] || echo "$raw_json" | grep -q '"error_code":401'; then
        status="AUTH_FAILED"
        error_desc="Telegram rejected the token (Unauthorized / Revoked)."
    elif [ "$http_code" -eq 403 ]; then
        status="NETWORK_RESTRICTED"
        error_desc="HTTP 403 Forbidden: Network or API access restricted."
    elif [ "$curl_rc" -eq 6 ] || echo "$err_text" | grep -qiE 'resolve|getaddrinfo|name resolution'; then
        status="DNS_FAILED"
        error_desc="DNS resolution for api.telegram.org failed."
    elif [ "$curl_rc" -eq 28 ] || echo "$err_text" | grep -qi 'timed out'; then
        status="NETWORK_TIMEOUT"
        error_desc="Connection to api.telegram.org timed out."
    elif [ "$curl_rc" -eq 35 ] || [ "$curl_rc" -eq 60 ] || echo "$err_text" | grep -qiE 'ssl|tls|certificate'; then
        status="TLS_FAILED"
        error_desc="SSL/TLS handshake or certificate verification failed."
    elif [ "$curl_rc" -eq 7 ] || echo "$err_text" | grep -qi 'connection refused'; then
        status="NETWORK_RESTRICTED"
        error_desc="Connection to api.telegram.org refused."
    else
        status="API_ERROR"
        local api_desc
        api_desc="$(echo "$raw_json" | grep -o '"description":"[^"]*"' | head -n1 | cut -d'"' -f4 || true)"
        error_desc="${api_desc:-HTTP $http_code / $err_text}"
    fi

    # Save to status cache
    telegram_init_dirs
    local cache_file="$TG_STATE_DIR/api_status.json"
    local now
    now="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date)"
    cat > "$cache_file" <<EOF
{
  "status": "$status",
  "http_code": $http_code,
  "bot_username": "$bot_username",
  "error": "$error_desc",
  "checked_at": "$now"
}
EOF
    chmod 0600 "$cache_file" 2>/dev/null || true

    printf '{"status":"%s","http_code":%d,"bot_username":"%s","error":"%s"}\n' \
        "$status" "$http_code" "$bot_username" "$error_desc"

    [ "$status" = "CONNECTED" ]
}

# Configure heartbeat parameters
telegram_configure_heartbeat() {
    local enabled="${1:-true}"
    local interval="${2:-7}"
    local mode="${3:-compact}"
    telegram_init_dirs

    local admins="\"admin_user_ids\": []"
    if [ -f "$TG_CONFIG_FILE" ]; then
        local a
        a="$(grep -o '"admin_user_ids": *\[[^]]*\]' "$TG_CONFIG_FILE" 2>/dev/null || true)"
        [ -n "$a" ] && admins="$a"
    fi

    cat > "$TG_CONFIG_FILE" <<EOF
{
  $admins,
  "heartbeat_enabled": $enabled,
  "heartbeat_interval_minutes": $interval,
  "heartbeat_mode": "$mode",
  "audit_logging": true
}
EOF
    chmod 0600 "$TG_CONFIG_FILE" 2>/dev/null || true
    log_ok "Telegram heartbeat settings updated (enabled: $enabled, interval: ${interval}m, mode: $mode)."
}

# Set authorized admin user IDs
telegram_set_users() {
    local uids="$*"
    telegram_init_dirs
    local json_arr="["
    local first=1
    for uid in $uids; do
        # Validate numeric
        if ! [[ "$uid" =~ ^[0-9]+$ ]]; then
            log_warn "Skipping non-numeric Telegram User ID: $uid"
            continue
        fi
        [ "$first" -eq 1 ] && first=0 || json_arr+=", "
        json_arr+="$uid"
    done
    json_arr+="]"

    local hb_enabled="true" hb_interval="7" hb_mode="compact"
    if [ -f "$TG_CONFIG_FILE" ]; then
        hb_enabled="$(grep -o '"heartbeat_enabled": *[a-zA-Z]*' "$TG_CONFIG_FILE" 2>/dev/null | awk '{print $2}' || echo "true")"
        hb_interval="$(grep -o '"heartbeat_interval_minutes": *[0-9]*' "$TG_CONFIG_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "7")"
        hb_mode="$(grep -o '"heartbeat_mode": *"[^"]*"' "$TG_CONFIG_FILE" 2>/dev/null | cut -d'"' -f4 || echo "compact")"
    fi

    cat > "$TG_CONFIG_FILE" <<EOF
{
  "admin_user_ids": $json_arr,
  "heartbeat_enabled": $hb_enabled,
  "heartbeat_interval_minutes": $hb_interval,
  "heartbeat_mode": "$hb_mode",
  "audit_logging": true
}
EOF
    chmod 0600 "$TG_CONFIG_FILE" 2>/dev/null || true
    log_ok "Telegram admin user IDs updated: $json_arr"
}

# Count configured admins
telegram_get_admin_count() {
    telegram_init_dirs
    if [ -f "$TG_CONFIG_FILE" ]; then
        local raw
        raw="$(grep -o '"admin_user_ids": *\[[^]]*\]' "$TG_CONFIG_FILE" 2>/dev/null || true)"
        if [ -n "$raw" ]; then
            local count
            count="$(echo "$raw" | grep -o '[0-9]\+' | wc -l || echo 0)"
            echo "$count"
            return 0
        fi
    fi
    echo 0
}

# Start Telegram bot as a persistent CyberVPS service
# Validates token and connectivity before registering
telegram_start() {
    telegram_init_dirs

    if ! telegram_has_token; then
        log_error "Telegram bot token not found. Set it with: cybervps telegram set-token <token>"
        return 1
    fi

    local token
    token="$(telegram_get_token)"
    if ! telegram_validate_token_format "$token"; then
        log_error "Configured bot token format is invalid. Run: cybervps telegram set-token <token>"
        return 1
    fi

    # Validate with getMe first to avoid endless crash loops
    log_info "Verifying bot token with Telegram API before launch..."
    local q_res
    q_res="$(telegram_query_getme "$token")"
    local q_status
    q_status="$(echo "$q_res" | grep -o '"status":"[^"]*"' | head -n1 | cut -d'"' -f4 || echo "UNKNOWN")"

    if [ "$q_status" = "AUTH_FAILED" ]; then
        log_error "Cannot start Telegram bot: Telegram rejected the token (Unauthorized/Revoked)."
        log_error "Please check and update your token with: cybervps telegram set-token <token>"
        return 1
    elif [ "$q_status" != "CONNECTED" ]; then
        local q_err
        q_err="$(echo "$q_res" | grep -o '"error":"[^"]*"' | head -n1 | cut -d'"' -f4 || true)"
        log_warn "Telegram API check returned '$q_status' ($q_err)."
        log_warn "Starting daemon anyway; bot will retry connection automatically in background."
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

    local admin_count
    admin_count="$(telegram_get_admin_count)"
    if [ "$admin_count" -eq 0 ]; then
        echo
        log_warn "No authorized administrator configured."
        echo -e "  ${C_BWHITE}Action:${C_RESET} Set your numeric Telegram ID so the bot accepts commands:"
        echo -e "  ${C_PRIMARY}cybervps telegram set-users <your_telegram_id>${C_RESET}\n"
    fi
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

# Show truthful status of Telegram bot, API, and heartbeat
telegram_status() {
    telegram_init_dirs
    echo -e "\n${C_PRIMARY}${C_BOLD}=== CyberVPS Telegram Remote Control Status ===${C_RESET}\n"

    # 1. Local Process State
    local is_proc_running=false
    is_service_running "cybervps-telegram" && is_proc_running=true
    if [ "$is_proc_running" = true ]; then
        echo -e "  Process       : ${C_SUCCESS}● RUNNING${C_RESET} (Persistent Supervisor)"
    else
        echo -e "  Process       : ${C_TEXT_MUTED}○ STOPPED${C_RESET}"
    fi

    # 2. Token State
    if telegram_has_token; then
        echo -e "  Token         : ${C_SUCCESS}● CONFIGURED${C_RESET} (0600 stored outside Git)"
    else
        echo -e "  Token         : ${C_WARN}○ NOT CONFIGURED${C_RESET}"
    fi

    # 3. API State (from cache or live query)
    local api_status="UNKNOWN" bot_name="" api_err=""
    if [ -f "$TG_STATE_DIR/api_status.json" ]; then
        api_status="$(grep -o '"status": *"[^"]*"' "$TG_STATE_DIR/api_status.json" 2>/dev/null | head -n1 | cut -d'"' -f4 || echo "UNKNOWN")"
        bot_name="$(grep -o '"bot_username": *"[^"]*"' "$TG_STATE_DIR/api_status.json" 2>/dev/null | head -n1 | cut -d'"' -f4 || true)"
        api_err="$(grep -o '"error": *"[^"]*"' "$TG_STATE_DIR/api_status.json" 2>/dev/null | head -n1 | cut -d'"' -f4 || true)"
    fi

    case "$api_status" in
        CONNECTED)
            echo -e "  API Access    : ${C_SUCCESS}● CONNECTED${C_RESET} (@${bot_name})"
            ;;
        AUTH_FAILED)
            echo -e "  API Access    : ${C_CRIT}✕ AUTH_FAILED${C_RESET} (Invalid or revoked token)"
            ;;
        DNS_FAILED|NETWORK_TIMEOUT|NETWORK_RESTRICTED)
            echo -e "  API Access    : ${C_WARN}✕ NETWORK_FAILED${C_RESET} (${api_err})"
            ;;
        *)
            echo -e "  API Access    : ${C_TEXT_MUTED}○ NOT TESTED${C_RESET} (Run: cybervps telegram test)"
            ;;
    esac

    # 4. Admins State
    local admin_count
    admin_count="$(telegram_get_admin_count)"
    if [ "$admin_count" -gt 0 ]; then
        echo -e "  Admins        : ${C_SUCCESS}● CONFIGURED${C_RESET} (${admin_count} authorized user(s))"
    else
        echo -e "  Admins        : ${C_WARN}○ NOT CONFIGURED${C_RESET} (Commands locked; set with: cybervps telegram set-users <ID>)"
    fi

    # 5. Heartbeat State
    if [ -f "$TG_CONFIG_FILE" ]; then
        local hb_on hb_interval hb_mode
        hb_on="$(grep -o '"heartbeat_enabled": *[a-zA-Z]*' "$TG_CONFIG_FILE" 2>/dev/null | awk '{print $2}' || echo "true")"
        hb_interval="$(grep -o '"heartbeat_interval_minutes": *[0-9]*' "$TG_CONFIG_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "7")"
        hb_mode="$(grep -o '"heartbeat_mode": *"[^"]*"' "$TG_CONFIG_FILE" 2>/dev/null | cut -d'"' -f4 || echo "compact")"

        if [ "$hb_on" = "true" ]; then
            echo -e "  Heartbeat     : ${C_SUCCESS}● ACTIVE${C_RESET} (Interval: ${hb_interval}m, Mode: ${hb_mode})"
        else
            echo -e "  Heartbeat     : ${C_TEXT_MUTED}○ DISABLED${C_RESET}"
        fi
    else
        echo -e "  Heartbeat     : ${C_SUCCESS}● ACTIVE${C_RESET} (Default: 7m, compact)"
    fi

    local state_f="$TG_STATE_DIR/state.json"
    if [ -f "$state_f" ]; then
        local last_s
        last_s="$(grep -o '"last_heartbeat_success": *"[^"]*"' "$state_f" 2>/dev/null | cut -d'"' -f4 || echo "None")"
        echo -e "  Last Delivery : ${C_TEXT}${last_s}${C_RESET}"
    fi
    echo
}

# Test connection to Telegram API with rich classification
telegram_test() {
    telegram_init_dirs
    local token
    token="$(telegram_get_token)"

    if [ -z "$token" ]; then
        log_error "Telegram bot token is not configured. Set it with: cybervps telegram set-token <token>"
        return 1
    fi

    echo -e "\n${C_PRIMARY}${C_BOLD}Telegram API Diagnostics${C_RESET}\n"

    # Local service process
    if is_service_running "cybervps-telegram"; then
        echo -e "  Process        : ${C_SUCCESS}● RUNNING${C_RESET}"
    else
        echo -e "  Process        : ${C_TEXT_MUTED}○ STOPPED${C_RESET}"
    fi

    # Network check for api.telegram.org
    local dns_ok=false
    if have_command getent && getent hosts api.telegram.org >/dev/null 2>&1; then
        dns_ok=true
    elif have_command ping && ping -c 1 -W 2 api.telegram.org >/dev/null 2>&1; then
        dns_ok=true
    elif have_command python3 && python3 -c "import socket; socket.gethostbyname('api.telegram.org')" >/dev/null 2>&1; then
        dns_ok=true
    fi

    if [ "$dns_ok" = true ]; then
        echo -e "  Network        : ${C_SUCCESS}✓ api.telegram.org reachable${C_RESET}"
    else
        echo -e "  Network        : ${C_WARN}✕ DNS resolution failed for api.telegram.org${C_RESET}"
    fi

    log_info "Testing Telegram API credentials via getMe..."
    local q_res
    q_res="$(telegram_query_getme "$token")"
    local q_status q_user q_err
    q_status="$(echo "$q_res" | grep -o '"status":"[^"]*"' | head -n1 | cut -d'"' -f4 || echo "UNKNOWN")"
    q_user="$(echo "$q_res" | grep -o '"bot_username":"[^"]*"' | head -n1 | cut -d'"' -f4 || true)"
    q_err="$(echo "$q_res" | grep -o '"error":"[^"]*"' | head -n1 | cut -d'"' -f4 || true)"

    if [ "$q_status" = "CONNECTED" ]; then
        echo -e "  Authentication : ${C_SUCCESS}✓ CONNECTED (@${q_user})${C_RESET}"
        echo -e "\n${C_SUCCESS}✅ CyberVPS Telegram connection test successful.${C_RESET}"
        return 0
    elif [ "$q_status" = "AUTH_FAILED" ]; then
        echo -e "  Authentication : ${C_CRIT}✕ FAILED${C_RESET}"
        echo -e "\n${C_CRIT}Reason:${C_RESET} Telegram rejected the configured bot token (Unauthorized / Revoked)."
        echo -e "${C_BWHITE}Action:${C_RESET} Obtain a valid token from @BotFather and save it with: ${C_PRIMARY}cybervps telegram set-token <token>${C_RESET}"
        return 1
    else
        echo -e "  Authentication : ${C_WARN}✕ FAILED (${q_status})${C_RESET}"
        echo -e "\n${C_WARN}Reason:${C_RESET} ${q_err}"
        return 1
    fi
}

# Full Telegram Subsystem Doctor
telegram_doctor() {
    telegram_init_dirs
    echo -e "\n${C_PRIMARY}${C_BOLD}CYBERVPS TELEGRAM SUBSYSTEM DOCTOR${C_RESET}\n"

    # 1. Token file check
    if [ -f "$TG_TOKEN_FILE" ] && [ -s "$TG_TOKEN_FILE" ]; then
        local perms
        perms="$(stat -c %a "$TG_TOKEN_FILE" 2>/dev/null || stat -f %Lp "$TG_TOKEN_FILE" 2>/dev/null || echo "0600")"
        if [ "$perms" = "600" ] || [ "$perms" = "0600" ]; then
            ui_step "DONE" "Token Storage" "Present at $TG_TOKEN_FILE (Permissions: 0600)"
        else
            ui_step "WARN" "Token Storage" "Present but permissions are $perms (Expected: 0600)"
            chmod 0600 "$TG_TOKEN_FILE" 2>/dev/null || true
        fi
    else
        ui_step "FAIL" "Token Storage" "Token file missing or empty"
    fi

    # 2. Token format validation
    local tok
    tok="$(telegram_get_token)"
    if [ -n "$tok" ]; then
        if telegram_validate_token_format "$tok"; then
            ui_step "DONE" "Token Format" "Valid Telegram Bot token structure"
        else
            ui_step "WARN" "Token Format" "Token does not match expected bot format"
        fi
    fi

    # 3. DNS Resolution
    local dns_res=false
    if have_command python3 && python3 -c "import socket; socket.gethostbyname('api.telegram.org')" >/dev/null 2>&1; then
        dns_res=true
    elif have_command getent && getent hosts api.telegram.org >/dev/null 2>&1; then
        dns_res=true
    fi
    if [ "$dns_res" = true ]; then
        ui_step "DONE" "DNS Resolution" "api.telegram.org resolved successfully"
    else
        ui_step "WARN" "DNS Resolution" "Cannot resolve api.telegram.org"
    fi

    # 4. API getMe
    if [ -n "$tok" ]; then
        local q_res q_status q_user
        q_res="$(telegram_query_getme "$tok")"
        q_status="$(echo "$q_res" | grep -o '"status":"[^"]*"' | head -n1 | cut -d'"' -f4 || echo "UNKNOWN")"
        q_user="$(echo "$q_res" | grep -o '"bot_username":"[^"]*"' | head -n1 | cut -d'"' -f4 || true)"
        if [ "$q_status" = "CONNECTED" ]; then
            ui_step "DONE" "API Verification" "Authenticated successfully as @${q_user}"
        elif [ "$q_status" = "AUTH_FAILED" ]; then
            ui_step "FAIL" "API Verification" "Token rejected by Telegram API (Unauthorized)"
        else
            ui_step "WARN" "API Verification" "API returned: $q_status"
        fi
    fi

    # 5. Authorized Administrators
    local admin_count
    admin_count="$(telegram_get_admin_count)"
    if [ "$admin_count" -gt 0 ]; then
        ui_step "DONE" "Admin Security" "$admin_count authorized admin ID(s) configured"
    else
        ui_step "PENDING" "Admin Security" "No admin user IDs configured (Remote commands disabled)"
    fi

    # 6. Service State
    if is_service_running "cybervps-telegram"; then
        ui_step "DONE" "Service Process" "Active under supervisor"
    else
        ui_step "PENDING" "Service Process" "Stopped"
    fi

    # 7. Agent Script
    if [ -f "$TG_AGENT_SCRIPT" ]; then
        ui_step "DONE" "Agent Script" "Found at $TG_AGENT_SCRIPT"
    else
        ui_step "FAIL" "Agent Script" "Missing: $TG_AGENT_SCRIPT"
    fi
    echo
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
        doctor)
            telegram_doctor
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
        configure-heartbeat)
            telegram_configure_heartbeat "$@"
            ;;
        set-users)
            telegram_set_users "$@"
            ;;
        help|--help|-h)
            echo "CyberVPS Telegram Remote Administration"
            echo "Usage: cybervps telegram <command> [args...]"
            echo
            echo "Commands:"
            echo "  start       Start Telegram bot daemon as persistent CyberVPS service"
            echo "  stop        Stop Telegram bot daemon"
            echo "  restart     Restart Telegram bot daemon"
            echo "  status      Display truthful bot state, API access, and heartbeat info"
            echo "  test        Test connectivity & credentials to Telegram API"
            echo "  doctor      Run comprehensive diagnostics on Telegram subsystem"
            echo "  logs        View Telegram service logs"
            echo "  set-token   Store bot token securely outside git (0600)"
            echo "  configure-heartbeat <true|false> [minutes] [mode]"
            echo "  set-users   <id1> [id2...]"
            ;;
        *)
            log_error "Unknown telegram command: '$action'. Try: cybervps telegram help"
            return 1
            ;;
    esac
}
