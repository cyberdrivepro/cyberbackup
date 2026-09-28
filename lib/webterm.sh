#!/usr/bin/env bash
# lib/webterm.sh — CyberVPS Authenticated Persistent Web Terminal
# Serves interactive browser terminal sessions over localhost:127.0.0.1
# Attached to CyberVPS persistent tmux sessions so browser disconnection
# never terminates shell processes.

[ -n "${_CYBERVPS_WEBTERM_SH_LOADED:-}" ] && return 0
_CYBERVPS_WEBTERM_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=lib/ports.sh
source "$LIB_DIR/ports.sh"
# shellcheck source=lib/sessions.sh
source "$LIB_DIR/sessions.sh"

WEBTERM_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cybervps/webterm"
WEBTERM_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/webterm"
WEBTERM_LOGS_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/logs/webterm"

webterm_init_dirs() {
    WEBTERM_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cybervps/webterm"
    WEBTERM_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/webterm"
    WEBTERM_LOGS_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/logs/webterm"

    ensure_directory "$WEBTERM_CONFIG_DIR" 0700
    ensure_directory "$WEBTERM_STATE_DIR" 0700
    ensure_directory "$WEBTERM_LOGS_DIR" 0755
}

# Ensure authentication credentials exist outside Git
webterm_ensure_auth() {
    webterm_init_dirs
    local auth_file="$WEBTERM_CONFIG_DIR/auth.env"

    if [ ! -f "$auth_file" ]; then
        local user="cybervps"
        local pass
        if have_command openssl; then
            pass="$(openssl rand -hex 16)"
        else
            pass="$(head -c 16 /dev/urandom 2>/dev/null | xxd -p 2>/dev/null || echo "cybervps-$RANDOM$RANDOM")"
        fi

        cat > "$auth_file" <<EOF
# CyberVPS Web Terminal Authentication Credentials
# Permissions: 0600 — Keep private, never commit to git
WEBTERM_USER="$user"
WEBTERM_PASS="$pass"
EOF
        chmod 0600 "$auth_file" 2>/dev/null || true
        log_ok "Generated web terminal credentials in $auth_file"
    fi
}

# Ensure ttyd binary is installed in user-space
webterm_ensure_installed() {
    if have_command ttyd; then
        return 0
    fi

    log_info "ttyd not found in PATH. Installing user-space binary..."
    local installer="$LIB_DIR/../installers/ttyd.sh"
    if [ -x "$installer" ]; then
        bash "$installer"
    else
        log_error "Installer $installer not found."
        return 1
    fi
}

# Check if webterm server is running
webterm_is_running() {
    webterm_init_dirs
    local pid_file="$WEBTERM_STATE_DIR/webterm.pid"
    if [ -f "$pid_file" ]; then
        local pid
        pid="$(cat "$pid_file" 2>/dev/null || true)"
        if [ -n "$pid" ] && [ "$pid" -gt 0 ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        rm -f "$pid_file"
    fi
    return 1
}

# Start the web terminal
webterm_start() {
    local target_session="${1:-main}"

    webterm_init_dirs
    webterm_ensure_installed || return 1
    webterm_ensure_auth

    if webterm_is_running; then
        log_info "Web terminal is already running."
        webterm_status
        return 0
    fi

    # Ensure target tmux session exists
    if ! session_is_alive "$target_session"; then
        log_info "Creating persistent session '$target_session' for web terminal..."
        session_new "$target_session"
    fi

    # Source auth credentials
    # shellcheck source=/dev/null
    source "$WEBTERM_CONFIG_DIR/auth.env"

    # Allocate dynamic port
    init_ports_config
    local port
    port="$(get_port WEB_TERMINAL_PORT 7681)"
    local bind_ip="127.0.0.1" # Strictly localhost

    local log_file="$WEBTERM_LOGS_DIR/webterm.log"
    local pid_file="$WEBTERM_STATE_DIR/webterm.pid"
    local meta_file="$WEBTERM_STATE_DIR/current.json"

    log_info "Starting web terminal on http://${bind_ip}:${port} (attaching to session: '$target_session')..."

    local attach_cmd="tmux attach-session -t cybervps-${target_session}"
    if ! have_command tmux; then
        attach_cmd="${SHELL:-/bin/bash} -l"
    fi

    # Launch ttyd server in background bound strictly to 127.0.0.1
    nohup ttyd -i "$bind_ip" -p "$port" -c "${WEBTERM_USER}:${WEBTERM_PASS}" -W bash -c "$attach_cmd" > "$log_file" 2>&1 &
    local pid=$!
    echo "$pid" > "$pid_file"

    local now
    now="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date)"

    cat > "$meta_file" <<EOF
{
  "state": "RUNNING",
  "pid": $pid,
  "bind": "$bind_ip",
  "port": $port,
  "session": "$target_session",
  "started_at": "$now",
  "url": "http://${bind_ip}:${port}"
}
EOF
    chmod 0600 "$meta_file" 2>/dev/null || true

    sleep 1
    if webterm_is_running; then
        log_ok "Web terminal active on http://${bind_ip}:${port}"
        echo -e "  • Authentication : ENABLED (User: ${WEBTERM_USER})"
        echo -e "  • Attached Session : cybervps-${target_session}"
        echo -e "  • Credentials File : $WEBTERM_CONFIG_DIR/auth.env (0600)"
        return 0
    else
        log_error "Web terminal failed to start. Check logs: $log_file"
        return 1
    fi
}

# Stop the web terminal
webterm_stop() {
    webterm_init_dirs
    local pid_file="$WEBTERM_STATE_DIR/webterm.pid"

    if [ -f "$pid_file" ]; then
        local pid
        pid="$(cat "$pid_file" 2>/dev/null || true)"
        if [ -n "$pid" ] && [ "$pid" -gt 0 ]; then
            kill "$pid" 2>/dev/null || true
            sleep 0.5
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$pid_file"
    fi

    rm -f "$WEBTERM_STATE_DIR/current.json"
    log_ok "Web terminal stopped. (Persistent tmux sessions remain alive)"
}

# Restart the web terminal
webterm_restart() {
    local target_session="${1:-}"
    webterm_stop
    sleep 1
    webterm_start "$target_session"
}

# Show status of web terminal
webterm_status() {
    webterm_init_dirs
    local meta_file="$WEBTERM_STATE_DIR/current.json"

    echo "=== CyberVPS Web Terminal Status ==="
    if webterm_is_running && [ -f "$meta_file" ]; then
        local port s_name started
        port="$(grep -o '"port": *[0-9]*' "$meta_file" | grep -o '[0-9]*')"
        s_name="$(grep -o '"session": *"[^"]*"' "$meta_file" | cut -d'"' -f4)"
        started="$(grep -o '"started_at": *"[^"]*"' "$meta_file" | cut -d'"' -f4)"

        echo "State            : RUNNING"
        echo "Local Bind       : 127.0.0.1:$port"
        echo "Attached Session : cybervps-$s_name"
        echo "Started At       : $started"
        echo "Authentication   : ENABLED"
        return 0
    else
        echo "State            : STOPPED"
        echo "Default Bind     : 127.0.0.1"
        return 1
    fi
}

# List available sessions ready for web terminal
webterm_sessions() {
    echo "=== Available Persistent Sessions for Web Terminal ==="
    session_list
}

# Switch web terminal to a specific session
webterm_open() {
    local name="$1"
    if [ -z "$name" ]; then
        echo "Usage: cybervps webterm open <session-name>"
        return 1
    fi
    webterm_restart "$name"
}

# View web terminal logs
webterm_logs() {
    webterm_init_dirs
    local lines="${1:-50}"
    local log_file="$WEBTERM_LOGS_DIR/webterm.log"
    if [ -f "$log_file" ]; then
        echo "=== Web Terminal Logs ($log_file) ==="
        tail -n "$lines" "$log_file"
    else
        echo "No web terminal logs recorded yet."
    fi
}

# Display configuration / credentials
webterm_configure() {
    webterm_init_dirs
    webterm_ensure_auth

    local auth_file="$WEBTERM_CONFIG_DIR/auth.env"
    echo "=== Web Terminal Configuration & Access ==="
    echo "Configuration Directory: $WEBTERM_CONFIG_DIR"
    echo "Credentials (0600):"
    sed 's/^/  /' "$auth_file"
    echo
    echo "To reset password, delete $auth_file and restart webterm."
}

# CLI Dispatcher
handle_webterm_cli() {
    local action="${1:-status}"
    shift || true

    case "$action" in
        start)
            webterm_start "${1:-main}"
            ;;
        stop)
            webterm_stop
            ;;
        restart)
            webterm_restart "${1:-}"
            ;;
        status)
            webterm_status
            ;;
        sessions)
            webterm_sessions
            ;;
        open)
            if [ $# -lt 1 ]; then
                echo "Usage: cybervps webterm open <name>"
                return 1
            fi
            webterm_open "$1"
            ;;
        logs)
            webterm_logs "${1:-50}"
            ;;
        configure|auth)
            webterm_configure
            ;;
        help|--help|-h)
            echo "CyberVPS Web Terminal Manager"
            echo "Usage: cybervps webterm <command> [args...]"
            echo
            echo "Commands:"
            echo "  start [name]   Start web terminal attached to persistent session (default: main)"
            echo "  stop           Stop web terminal server (session remains alive)"
            echo "  restart [name] Restart web terminal server"
            echo "  status         Display running state, bind, port, and session"
            echo "  sessions       List available persistent sessions"
            echo "  open <name>    Switch web terminal to session <name>"
            echo "  logs           View web terminal server logs"
            echo "  configure      Display/manage access credentials"
            ;;
        *)
            log_error "Unknown webterm command: '$action'. Try: cybervps webterm help"
            return 1
            ;;
    esac
}
