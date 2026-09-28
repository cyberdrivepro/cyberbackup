#!/usr/bin/env bash
# lib/tunnel.sh — CyberVPS Secure Cloudflare Tunnel Remote Access
# Provides optional, rootless remote access via Cloudflare Quick Tunnels
# or Named Tunnels without exposing raw localhost ports to the public internet.

[ -n "${_CYBERVPS_TUNNEL_SH_LOADED:-}" ] && return 0
_CYBERVPS_TUNNEL_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=lib/ports.sh
source "$LIB_DIR/ports.sh"

TUNNEL_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cybervps/cloudflared"
TUNNEL_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/tunnel"
TUNNEL_LOGS_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/logs"

tunnel_init_dirs() {
    TUNNEL_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cybervps/cloudflared"
    TUNNEL_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/tunnel"
    TUNNEL_LOGS_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/logs"

    ensure_directory "$TUNNEL_CONFIG_DIR" 0700
    ensure_directory "$TUNNEL_STATE_DIR" 0700
    ensure_directory "$TUNNEL_LOGS_DIR" 0755
}

# Ensure cloudflared binary is installed
tunnel_ensure_installed() {
    if have_command cloudflared; then
        return 0
    fi
    if [ -x "${HOME}/bin/cloudflared" ]; then
        export PATH="${HOME}/bin:$PATH"
        return 0
    fi
    if [ -x "${HOME}/.local/bin/cloudflared" ]; then
        export PATH="${HOME}/.local/bin:$PATH"
        return 0
    fi

    log_info "cloudflared not found in PATH. Running user-space installer..."
    local installer="$LIB_DIR/../installers/cloudflared.sh"
    if [ -x "$installer" ]; then
        bash "$installer"
        export PATH="${HOME}/bin:$PATH"
    else
        log_error "Cloudflared installer not found at $installer"
        return 1
    fi
}

# Check if tunnel is running
tunnel_is_running() {
    local target="$1"
    tunnel_init_dirs
    local pid_file="$TUNNEL_STATE_DIR/${target}.pid"
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

# Start Cloudflare tunnel for a target service (e.g. webterm, dashboard, port)
tunnel_start() {
    local target="${1:-webterm}"

    tunnel_init_dirs
    tunnel_ensure_installed || return 1

    if tunnel_is_running "$target"; then
        log_info "Tunnel for '$target' is already running."
        tunnel_status "$target"
        return 0
    fi

    local port=0
    case "$target" in
        webterm)
            init_ports_config
            port="$(get_port WEB_TERMINAL_PORT 7681)"
            ;;
        dashboard|web)
            init_ports_config
            port="$(get_port WEB_PORT 8080)"
            ;;
        *)
            if [[ "$target" =~ ^[0-9]+$ ]]; then
                port="$target"
                target="port-${port}"
            else
                log_error "Unknown tunnel target '$target'. Specify 'webterm' or a local port number."
                return 1
            fi
            ;;
    esac

    local pid_file="$TUNNEL_STATE_DIR/${target}.pid"
    local meta_file="$TUNNEL_STATE_DIR/${target}.json"
    local log_file="$TUNNEL_LOGS_DIR/tunnel_${target}.log"

    log_info "Starting Cloudflare Quick Tunnel for target '$target' (127.0.0.1:${port})..."

    # Launch cloudflared quick tunnel detached
    nohup cloudflared tunnel --url "http://127.0.0.1:${port}" --no-autoupdate > "$log_file" 2>&1 &
    local pid=$!
    echo "$pid" > "$pid_file"

    # Wait briefly and parse tunnel URL from log file
    local url=""
    local i=0
    while [ $i -lt 15 ]; do
        sleep 1
        i=$((i + 1))
        url="$(grep -o 'https://[-a-zA-Z0-9\.]*\.trycloudflare\.com' "$log_file" 2>/dev/null | head -n1 || true)"
        [ -n "$url" ] && break
    done

    local now
    now="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date)"

    cat > "$meta_file" <<EOF
{
  "target": "$target",
  "port": $port,
  "pid": $pid,
  "type": "quick_tunnel",
  "url": "${url:-pending}",
  "started_at": "$now"
}
EOF
    chmod 0600 "$meta_file" 2>/dev/null || true

    if tunnel_is_running "$target"; then
        log_ok "Cloudflare Tunnel active for '$target' (PID: $pid)."
        if [ -n "$url" ]; then
            echo -e "  • Mode      : TEMPORARY PUBLIC URL (Cloudflare Quick Tunnel)"
            echo -e "  • Public URL: ${url}"
            echo -e "  • Local Bind: http://127.0.0.1:${port}"
        else
            echo -e "  • Tunnel starting in background; URL will appear shortly in: $log_file"
        fi
        return 0
    else
        log_error "Tunnel failed to start. Check logs: $log_file"
        return 1
    fi
}

# Stop tunnel
tunnel_stop() {
    local target="${1:-webterm}"
    tunnel_init_dirs

    local pid_file="$TUNNEL_STATE_DIR/${target}.pid"
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

    rm -f "$TUNNEL_STATE_DIR/${target}.json"
    log_ok "Cloudflare tunnel for '$target' stopped."
}

# Status of tunnel
tunnel_status() {
    local target="${1:-webterm}"
    tunnel_init_dirs

    local meta_file="$TUNNEL_STATE_DIR/${target}.json"
    local log_file="$TUNNEL_LOGS_DIR/tunnel_${target}.log"

    echo "=== CyberVPS Cloudflare Tunnel Status: $target ==="
    if tunnel_is_running "$target" && [ -f "$meta_file" ]; then
        local url port started pid
        url="$(grep -o '"url": *"[^"]*"' "$meta_file" 2>/dev/null | cut -d'"' -f4)"
        if [ "$url" = "pending" ] && [ -f "$log_file" ]; then
            url="$(grep -o 'https://[-a-zA-Z0-9\.]*\.trycloudflare\.com' "$log_file" 2>/dev/null | head -n1 || echo "pending")"
        fi
        port="$(grep -o '"port": *[0-9]*' "$meta_file" 2>/dev/null | grep -o '[0-9]*')"
        started="$(grep -o '"started_at": *"[^"]*"' "$meta_file" 2>/dev/null | cut -d'"' -f4)"
        pid="$(cat "$TUNNEL_STATE_DIR/${target}.pid" 2>/dev/null || echo 0)"

        echo "State      : RUNNING"
        echo "PID        : $pid"
        echo "Target     : 127.0.0.1:$port"
        echo "Public URL : $url"
        echo "Started At : $started"
        echo "Note       : Quick Tunnel URLs are temporary and regenerate on restart."
        return 0
    else
        echo "State      : STOPPED"
        return 1
    fi
}

# View tunnel logs
tunnel_logs() {
    local target="${1:-webterm}"
    local lines="${2:-50}"
    tunnel_init_dirs

    local log_file="$TUNNEL_LOGS_DIR/tunnel_${target}.log"
    if [ -f "$log_file" ]; then
        echo "=== Cloudflare Tunnel Logs ($target) ==="
        tail -n "$lines" "$log_file"
    else
        echo "No tunnel logs recorded for '$target'."
    fi
}

# CLI Dispatcher
handle_tunnel_cli() {
    local action="${1:-status}"
    shift || true
    local target="${1:-webterm}"
    shift || true

    case "$action" in
        start)
            tunnel_start "$target"
            ;;
        stop)
            tunnel_stop "$target"
            ;;
        status)
            tunnel_status "$target"
            ;;
        logs)
            tunnel_logs "$target" "${1:-50}"
            ;;
        help|--help|-h)
            echo "CyberVPS Cloudflare Tunnel Manager"
            echo "Usage: cybervps tunnel <command> [target]"
            echo
            echo "Commands:"
            echo "  start [target]   Start tunnel for target (webterm, dashboard, or port)"
            echo "  stop [target]    Stop running tunnel"
            echo "  status [target]  Display tunnel connection state and public URL"
            echo "  logs [target]    View tunnel daemon logs"
            ;;
        *)
            log_error "Unknown tunnel command: '$action'. Try: cybervps tunnel help"
            return 1
            ;;
    esac
}
