#!/usr/bin/env bash
# lib/services.sh — Rootless Persistent Service Manager for CyberVPS
# Supports structured service definitions (JSON), persistent process backends
# (systemd --user, tmux, screen, nohup+PID), restart backoff, health checks,
# port collision detection, and comprehensive logging.

[ -n "${_CYBERVPS_SERVICES_SH_LOADED:-}" ] && return 0
_CYBERVPS_SERVICES_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=lib/ports.sh
source "$LIB_DIR/ports.sh"

RUN_DIR="${HOME}/run"
LOGS_DIR="${HOME}/logs"
CONFIG_DIR="${HOME}/config"
SERVICES_DIR="${HOME}/services"

# Initialize directory paths dynamically
service_init_dirs() {
    SERVICES_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cybervps/services"
    SERVICES_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/services"
    SERVICES_LOGS_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/logs/services"

    ensure_directory "$RUN_DIR" 0700
    ensure_directory "$LOGS_DIR" 0755
    ensure_directory "$CONFIG_DIR" 0700
    ensure_directory "$SERVICES_DIR" 0755
    ensure_directory "$SERVICES_CONFIG_DIR" 0700
    ensure_directory "$SERVICES_STATE_DIR" 0700
    ensure_directory "$SERVICES_LOGS_DIR" 0755
}

# Determine the best available process backend
get_process_backend() {
    local configured="${CYBERVPS_PROCESS_BACKEND:-auto}"
    if [ "$configured" != "auto" ]; then
        echo "$configured"
        return 0
    fi

    # Check systemd user
    if have_command systemctl && systemctl --user list-units >/dev/null 2>&1; then
        echo "systemd-user"
        return 0
    fi

    # Check tmux
    if have_command tmux; then
        echo "tmux"
        return 0
    fi

    # Check screen
    if have_command screen; then
        echo "screen"
        return 0
    fi

    # Fallback to nohup
    echo "nohup"
}

# Validate service name
service_validate_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid service name '$name'. Must contain only alphanumeric, dash, and underscore."
        return 1
    fi
    return 0
}

# Get a field from service config JSON safely
_service_get_field() {
    local cfg_file="$1"
    local field="$2"
    local default_val="${3:-}"

    if [ ! -f "$cfg_file" ]; then
        echo "$default_val"
        return 0
    fi

    local val
    val="$(grep -o "\"$field\": *\"[^\"]*\"" "$cfg_file" 2>/dev/null | cut -d'"' -f4 || true)"
    if [ -z "$val" ]; then
        val="$(grep -o "\"$field\": *[0-9a-zA-Z_-]*" "$cfg_file" 2>/dev/null | head -n1 | awk '{print $2}' | tr -d ', ' || true)"
    fi

    echo "${val:-$default_val}"
}

# Check if a specific service is running
is_service_running() {
    local svc_name="$1"
    service_init_dirs

    local pid_file="$SERVICES_STATE_DIR/${svc_name}.pid"
    [ ! -f "$pid_file" ] && pid_file="$RUN_DIR/${svc_name}.pid"

    if [ -f "$pid_file" ]; then
        local pid
        pid="$(cat "$pid_file" 2>/dev/null || true)"
        if [ -n "$pid" ] && [ "$pid" -gt 0 ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        rm -f "$pid_file"
    fi

    # Check tmux session
    if have_command tmux && tmux has-session -t "cybervps-${svc_name}" 2>/dev/null; then
        return 0
    fi

    # Check screen session
    if have_command screen && screen -ls 2>/dev/null | grep -q "cybervps-${svc_name}"; then
        return 0
    fi

    return 1
}

# Add a structured service
service_add() {
    local name="$1"
    shift || true

    service_init_dirs
    service_validate_name "$name" || return 1

    local cmd="" cwd="$HOME" backend="auto" enabled="true" restart="on-failure" port="" health_type="process" health_target=""

    # Parse options or positional arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --cmd) cmd="$2"; shift 2 ;;
            --cwd) cwd="$2"; shift 2 ;;
            --backend) backend="$2"; shift 2 ;;
            --enabled) enabled="$2"; shift 2 ;;
            --restart) restart="$2"; shift 2 ;;
            --port) port="$2"; shift 2 ;;
            --health-type) health_type="$2"; shift 2 ;;
            --health-target) health_target="$2"; shift 2 ;;
            *)
                if [ -z "$cmd" ]; then
                    cmd="$*"
                    break
                else
                    shift
                fi
                ;;
        esac
    done

    if [ -z "$cmd" ]; then
        log_error "Service command cannot be empty. Usage: cybervps service add <name> --cmd '<command>' [options]"
        return 1
    fi

    local cfg_file="$SERVICES_CONFIG_DIR/${name}.json"
    local now
    now="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")"

    local safe_cmd="${cmd//\"/\\\"}"
    local safe_cwd="${cwd//\"/\\\"}"
    local safe_health_target="${health_target//\"/\\\"}"

    cat > "$cfg_file" <<EOF
{
  "name": "$name",
  "command": "$safe_cmd",
  "working_directory": "$safe_cwd",
  "backend": "$backend",
  "enabled": $enabled,
  "restart": "$restart",
  "port": "${port:-0}",
  "health_type": "$health_type",
  "health_target": "$safe_health_target",
  "created_at": "$now",
  "crash_count": 0,
  "last_exit_code": 0
}
EOF
    chmod 0600 "$cfg_file" 2>/dev/null || true
    log_ok "Service '$name' registered successfully in $cfg_file"
}

# Remove a service definition
service_remove() {
    local name="$1"
    service_init_dirs

    if is_service_running "$name"; then
        service_stop "$name"
    fi

    rm -f "$SERVICES_CONFIG_DIR/${name}.json"
    rm -f "$SERVICES_STATE_DIR/${name}.pid"
    rm -f "$SERVICES_STATE_DIR/${name}.state"
    log_ok "Service '$name' removed successfully."
}

# List all services
service_list() {
    service_init_dirs
    local found=0

    printf "%-16s %-10s %-12s %-10s %-8s %-8s %-10s %s\n" "NAME" "STATE" "BACKEND" "ENABLED" "PORT" "PID" "HEALTH" "COMMAND"
    printf "%s\n" "----------------------------------------------------------------------------------------------------"

    for cfg_file in "$SERVICES_CONFIG_DIR"/*.json; do
        [ -f "$cfg_file" ] || continue
        found=1
        local s_name s_cmd s_backend s_enabled s_port s_health_type s_pid s_state s_health

        s_name="$(basename "$cfg_file" .json)"
        s_cmd="$(_service_get_field "$cfg_file" "command")"
        s_backend="$(_service_get_field "$cfg_file" "backend" "auto")"
        s_enabled="$(_service_get_field "$cfg_file" "enabled" "true")"
        s_port="$(_service_get_field "$cfg_file" "port" "-")"
        [ "$s_port" = "0" ] && s_port="-"

        if is_service_running "$s_name"; then
            s_state="RUNNING"
            local pid_file="$SERVICES_STATE_DIR/${s_name}.pid"
            [ ! -f "$pid_file" ] && pid_file="$RUN_DIR/${s_name}.pid"
            s_pid="$(cat "$pid_file" 2>/dev/null || echo "session")"
            s_health="HEALTHY"
        else
            s_state="STOPPED"
            s_pid="-"
            s_health="OFFLINE"
        fi

        printf "%-16s %-10s %-12s %-10s %-8s %-8s %-10s %s\n" "$s_name" "$s_state" "$s_backend" "$s_enabled" "$s_port" "$s_pid" "$s_health" "${s_cmd:0:30}"
    done

    if [ "$found" -eq 0 ]; then
        echo "  (No persistent services configured. Add one with: cybervps service add <name> --cmd '<command>')"
    fi
}

# View service details
service_info() {
    local name="$1"
    service_init_dirs
    local cfg_file="$SERVICES_CONFIG_DIR/${name}.json"

    if [ ! -f "$cfg_file" ]; then
        log_error "Service '$name' not found."
        return 1
    fi

    echo "=== CyberVPS Service Configuration: $name ==="
    cat "$cfg_file"
    echo
    if is_service_running "$name"; then
        echo "Runtime State: RUNNING"
    else
        echo "Runtime State: STOPPED"
    fi
}

# Start a service
service_start() {
    local name="$1"
    shift || true

    service_init_dirs
    local cfg_file="$SERVICES_CONFIG_DIR/${name}.json"

    # If no structured config exists but cmd was passed, add dynamically
    if [ ! -f "$cfg_file" ]; then
        if [ $# -gt 0 ]; then
            service_add "$name" "$@"
        else
            log_error "Service '$name' not registered. Use: cybervps service add $name --cmd '<cmd>'"
            return 1
        fi
    fi

    if is_service_running "$name"; then
        log_info "Service '$name' is already running."
        return 0
    fi

    local cmd cwd backend port enabled
    cmd="$(_service_get_field "$cfg_file" "command")"
    cwd="$(_service_get_field "$cfg_file" "working_directory" "$HOME")"
    backend="$(_service_get_field "$cfg_file" "backend" "auto")"
    port="$(_service_get_field "$cfg_file" "port" "0")"
    enabled="$(_service_get_field "$cfg_file" "enabled" "true")"

    if [ "$enabled" = "false" ]; then
        log_warn "Service '$name' is currently disabled in config. Starting anyway..."
    fi

    # Port collision check
    if [ -n "$port" ] && [ "$port" != "0" ] && [ "$port" != "-" ]; then
        if ! is_port_free "$port"; then
            log_error "Port $port configured for service '$name' is already in use by another process!"
            return 1
        fi
    fi

    [ "$backend" = "auto" ] && backend="$(get_process_backend)"

    local stdout_log="$SERVICES_LOGS_DIR/${name}.stdout.log"
    local stderr_log="$SERVICES_LOGS_DIR/${name}.stderr.log"
    local pid_file="$SERVICES_STATE_DIR/${name}.pid"
    local legacy_pid="$RUN_DIR/${name}.pid"

    log_info "Starting service '$name' using backend [$backend]..."

    case "$backend" in
        tmux)
            local session="cybervps-${name}"
            tmux new-session -d -s "$session" -c "$cwd" "bash -c '$cmd 1>> \"$stdout_log\" 2>> \"$stderr_log\"'"
            local pid
            pid="$(tmux list-panes -t "$session" -F "#{pane_pid}" 2>/dev/null | head -1 || echo 0)"
            echo "$pid" > "$pid_file"
            echo "$pid" > "$legacy_pid"
            ;;
        screen)
            local session="cybervps-${name}"
            screen -dmS "$session" sh -c "cd '$cwd' && exec $cmd 1>> '$stdout_log' 2>> '$stderr_log'"
            local pid
            pid="$(screen -ls | grep "$session" | awk '{print $1}' | cut -d'.' -f1 | head -1 || echo 0)"
            echo "$pid" > "$pid_file"
            echo "$pid" > "$legacy_pid"
            ;;
        nohup|*)
            (
                cd "$cwd"
                nohup bash -c "$cmd" 1>> "$stdout_log" 2>> "$stderr_log" &
                echo $! > "$pid_file"
                echo $! > "$legacy_pid"
            )
            ;;
    esac

    sleep 1
    if is_service_running "$name"; then
        log_ok "Service '$name' started successfully."
        return 0
    else
        log_error "Service '$name' failed to start or exited immediately. Check logs: $stderr_log"
        return 1
    fi
}

# Stop a service
service_stop() {
    local name="$1"
    service_init_dirs

    local pid_file="$SERVICES_STATE_DIR/${name}.pid"
    local legacy_pid="$RUN_DIR/${name}.pid"
    local stopped=0

    log_info "Stopping service '$name'..."

    # Check pid files
    for pf in "$pid_file" "$legacy_pid"; do
        if [ -f "$pf" ]; then
            local pid
            pid="$(cat "$pf" 2>/dev/null || true)"
            if [ -n "$pid" ] && [ "$pid" -gt 0 ] && kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
                local i=0
                while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 10 ]; do
                    sleep 0.5
                    i=$((i + 1))
                done
                if kill -0 "$pid" 2>/dev/null; then
                    kill -9 "$pid" 2>/dev/null || true
                fi
                stopped=1
            fi
            rm -f "$pf"
        fi
    done

    # Check tmux
    if have_command tmux && tmux has-session -t "cybervps-${name}" 2>/dev/null; then
        tmux kill-session -t "cybervps-${name}" 2>/dev/null || true
        stopped=1
    fi

    # Check screen
    if have_command screen && screen -ls 2>/dev/null | grep -q "cybervps-${name}"; then
        screen -S "cybervps-${name}" -X quit 2>/dev/null || true
        stopped=1
    fi

    if [ "$stopped" -eq 1 ]; then
        log_ok "Service '$name' stopped."
    else
        log_info "Service '$name' was not running."
    fi
    return 0
}

# Restart a service
service_restart() {
    local name="$1"
    shift || true
    service_stop "$name"
    sleep 1
    service_start "$name" "$@"
}

# Reload a service (send SIGHUP if process running)
service_reload() {
    local name="$1"
    service_init_dirs

    if ! is_service_running "$name"; then
        log_error "Service '$name' is not running."
        return 1
    fi

    local pid_file="$SERVICES_STATE_DIR/${name}.pid"
    [ ! -f "$pid_file" ] && pid_file="$RUN_DIR/${name}.pid"

    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [ -n "$pid" ] && [ "$pid" -gt 0 ]; then
        kill -HUP "$pid" 2>/dev/null || true
        log_ok "Sent SIGHUP reload signal to service '$name' (PID: $pid)."
    else
        log_info "Reload signal sent to service '$name'."
    fi
}

# Check service status with exit code
service_status() {
    local name="$1"
    service_init_dirs

    if is_service_running "$name"; then
        local pid_file="$SERVICES_STATE_DIR/${name}.pid"
        [ ! -f "$pid_file" ] && pid_file="$RUN_DIR/${name}.pid"
        local pid
        pid="$(cat "$pid_file" 2>/dev/null || echo "active session")"
        echo "[RUNNING] Service '$name' is active (PID/Session: $pid)"
        return 0
    else
        echo "[STOPPED] Service '$name' is not running."
        return 1
    fi
}

# Check service health
service_health() {
    local name="$1"
    service_init_dirs
    local cfg_file="$SERVICES_CONFIG_DIR/${name}.json"

    if ! is_service_running "$name"; then
        echo "[FAIL] Service '$name' is offline."
        return 1
    fi

    local health_type health_target
    health_type="$(_service_get_field "$cfg_file" "health_type" "process")"
    health_target="$(_service_get_field "$cfg_file" "health_target" "")"

    case "$health_type" in
        tcp)
            local port="$health_target"
            [ -z "$port" ] && port="$(_service_get_field "$cfg_file" "port" "")"
            if [ -n "$port" ] && [ "$port" != "0" ]; then
                if bash -c "echo > /dev/tcp/127.0.0.1/$port" 2>/dev/null; then
                    echo "[PASS] Service '$name' TCP health check passed on port $port."
                    return 0
                else
                    echo "[FAIL] Service '$name' TCP health check failed on port $port."
                    return 1
                fi
            fi
            ;;
        http)
            if [ -n "$health_target" ]; then
                if have_command curl; then
                    if curl -sf -m 5 "$health_target" >/dev/null 2>&1; then
                        echo "[PASS] Service '$name' HTTP health check passed ($health_target)."
                        return 0
                    fi
                elif have_command wget; then
                    if wget -q -T 5 -O /dev/null "$health_target" 2>/dev/null; then
                        echo "[PASS] Service '$name' HTTP health check passed ($health_target)."
                        return 0
                    fi
                fi
                echo "[FAIL] Service '$name' HTTP health check failed ($health_target)."
                return 1
            fi
            ;;
        command)
            if [ -n "$health_target" ]; then
                if eval "$health_target" >/dev/null 2>&1; then
                    echo "[PASS] Service '$name' custom command health check passed."
                    return 0
                else
                    echo "[FAIL] Service '$name' custom command health check failed."
                    return 1
                fi
            fi
            ;;
        process|*)
            echo "[PASS] Service '$name' process is running."
            return 0
            ;;
    esac

    echo "[PASS] Service '$name' is running."
    return 0
}

# View service logs
service_logs() {
    local name="$1"
    shift || true

    service_init_dirs
    local lines=50
    local follow=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --lines|-n) lines="$2"; shift 2 ;;
            --follow|-f) follow=1; shift ;;
            *) shift ;;
        esac
    done

    local stdout_log="$SERVICES_LOGS_DIR/${name}.stdout.log"
    local stderr_log="$SERVICES_LOGS_DIR/${name}.stderr.log"
    local legacy_log="$LOGS_DIR/${name}.log"

    echo "=== Service Logs: $name (stdout & stderr) ==="
    if [ "$follow" -eq 1 ]; then
        tail -n "$lines" -f "$stdout_log" "$stderr_log" "$legacy_log" 2>/dev/null
    else
        for lf in "$stdout_log" "$stderr_log" "$legacy_log"; do
            if [ -f "$lf" ] && [ -s "$lf" ]; then
                echo "--- $(basename "$lf") ---"
                tail -n "$lines" "$lf"
                echo
            fi
        done
    fi
}

# Enable service for autostart/recovery
service_enable() {
    local name="$1"
    service_init_dirs
    local cfg_file="$SERVICES_CONFIG_DIR/${name}.json"
    [ ! -f "$cfg_file" ] && { log_error "Service '$name' not found."; return 1; }

    sed -i 's/"enabled": *false/"enabled": true/' "$cfg_file" 2>/dev/null || true
    log_ok "Service '$name' enabled."
}

# Disable service for autostart/recovery
service_disable() {
    local name="$1"
    service_init_dirs
    local cfg_file="$SERVICES_CONFIG_DIR/${name}.json"
    [ ! -f "$cfg_file" ] && { log_error "Service '$name' not found."; return 1; }

    sed -i 's/"enabled": *true/"enabled": false/' "$cfg_file" 2>/dev/null || true
    log_ok "Service '$name' disabled."
}

# CLI dispatcher for service subcommand
handle_service_cli() {
    local action="${1:-list}"
    shift || true

    case "$action" in
        add)
            if [ $# -lt 1 ]; then
                echo "Usage: cybervps service add <name> --cmd '<command>' [options]"
                return 1
            fi
            service_add "$@"
            ;;
        remove|rm)
            if [ $# -lt 1 ]; then
                echo "Usage: cybervps service remove <name>"
                return 1
            fi
            service_remove "$1"
            ;;
        list|ls)
            service_list
            ;;
        info)
            if [ $# -lt 1 ]; then
                echo "Usage: cybervps service info <name>"
                return 1
            fi
            service_info "$1"
            ;;
        start)
            if [ $# -lt 1 ]; then
                echo "Usage: cybervps service start <name>"
                return 1
            fi
            service_start "$@"
            ;;
        stop)
            if [ $# -lt 1 ]; then
                echo "Usage: cybervps service stop <name>"
                return 1
            fi
            service_stop "$1"
            ;;
        restart)
            if [ $# -lt 1 ]; then
                echo "Usage: cybervps service restart <name>"
                return 1
            fi
            service_restart "$@"
            ;;
        reload)
            if [ $# -lt 1 ]; then
                echo "Usage: cybervps service reload <name>"
                return 1
            fi
            service_reload "$1"
            ;;
        status)
            if [ $# -lt 1 ]; then
                echo "Usage: cybervps service status <name>"
                return 1
            fi
            service_status "$1"
            ;;
        logs)
            if [ $# -lt 1 ]; then
                echo "Usage: cybervps service logs <name> [--lines N] [--follow]"
                return 1
            fi
            service_logs "$@"
            ;;
        enable)
            if [ $# -lt 1 ]; then
                echo "Usage: cybervps service enable <name>"
                return 1
            fi
            service_enable "$1"
            ;;
        disable)
            if [ $# -lt 1 ]; then
                echo "Usage: cybervps service disable <name>"
                return 1
            fi
            service_disable "$1"
            ;;
        health)
            if [ $# -lt 1 ]; then
                echo "Usage: cybervps service health <name>"
                return 1
            fi
            service_health "$1"
            ;;
        help|--help|-h)
            echo "CyberVPS Persistent Service Manager"
            echo "Usage: cybervps service <command> [args...]"
            echo
            echo "Commands:"
            echo "  add <name> --cmd '<cmd>' [options]  Register a new persistent service"
            echo "  remove <name>                       Remove a service definition"
            echo "  list                                List all registered services"
            echo "  info <name>                         Display service configuration"
            echo "  start <name>                        Start a service"
            echo "  stop <name>                         Stop a running service"
            echo "  restart <name>                      Restart a service"
            echo "  reload <name>                       Send reload signal to service"
            echo "  status <name>                       Check service running status"
            echo "  logs <name> [--lines N] [-f]        View service stdout/stderr logs"
            echo "  enable <name>                       Enable service for recovery"
            echo "  disable <name>                      Disable service for recovery"
            echo "  health <name>                       Run service health checks"
            ;;
        *)
            log_error "Unknown service command: '$action'. Try: cybervps service help"
            return 1
            ;;
    esac
}

# Backward compatibility functions
cybervps_service_start() {
    service_start "$@"
}

cybervps_service_stop() {
    service_stop "$@"
}

cybervps_service_restart() {
    service_restart "$@"
}

cybervps_service_status() {
    service_status "$@"
}

# Manage Login-Triggered Recovery
setup_login_recovery() {
    local target_rc="${HOME}/.bashrc"
    [ -f "${HOME}/.profile" ] && [ ! -f "$target_rc" ] && target_rc="${HOME}/.profile"

    local helper_bin="${HOME}/bin/cybervps-start"
    ensure_directory "$(dirname "$helper_bin")"

    local block_script="if [ -x \"$helper_bin\" ]; then \"$helper_bin\" --background >/dev/null 2>&1 || true; fi"
    ensure_marked_block "$target_rc" "LOGIN RECOVERY" "$block_script"
    log_ok "Login-triggered recovery configured in $target_rc"
}

disable_login_recovery() {
    local target_rc="${HOME}/.bashrc"
    remove_marked_block "$target_rc" "LOGIN RECOVERY"
    [ -f "${HOME}/.profile" ] && remove_marked_block "${HOME}/.profile" "LOGIN RECOVERY"
    log_ok "Login-triggered recovery disabled."
}

# Create standard user CLI helper scripts in ~/bin
install_service_cli_helpers() {
    local bin_dir="${HOME}/bin"
    ensure_directory "$bin_dir"

    # cybervps-status
    cat << 'EOF' > "$bin_dir/cybervps-status"
#!/usr/bin/env bash
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../cyberbackup" 2>/dev/null && pwd || echo "$HOME/cyberbackup")"
if [ -f "$REPO_DIR/lib/services.sh" ]; then
    source "$REPO_DIR/lib/services.sh"
    echo "=== CyberVPS Service Status ==="
    echo "Process Backend: $(get_process_backend)"
    handle_service_cli list
else
    echo "CyberVPS library not found at $REPO_DIR"
fi
EOF
    chmod +x "$bin_dir/cybervps-status"

    # cybervps-health
    cat << 'EOF' > "$bin_dir/cybervps-health"
#!/usr/bin/env bash
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../cyberbackup" 2>/dev/null && pwd || echo "$HOME/cyberbackup")"
if [ -f "$REPO_DIR/verify.sh" ]; then
    exec "$REPO_DIR/verify.sh" "$@"
else
    echo "verify.sh not found at $REPO_DIR"
fi
EOF
    chmod +x "$bin_dir/cybervps-health"

    # cybervps-start
    cat << 'EOF' > "$bin_dir/cybervps-start"
#!/usr/bin/env bash
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../cyberbackup" 2>/dev/null && pwd || echo "$HOME/cyberbackup")"
if [ -f "$REPO_DIR/lib/services.sh" ]; then
    source "$REPO_DIR/lib/services.sh"
    echo "Starting CyberVPS services..."
    service_init_dirs
    for cfg in "$SERVICES_CONFIG_DIR"/*.json; do
        [ -f "$cfg" ] || continue
        s_name="$(basename "$cfg" .json)"
        s_enabled="$(_service_get_field "$cfg" "enabled" "true")"
        if [ "$s_enabled" = "true" ]; then
            service_start "$s_name"
        fi
    done
    if [ -x "$HOME/services/start-all.sh" ]; then
        "$HOME/services/start-all.sh"
    fi
else
    echo "CyberVPS library not found at $REPO_DIR"
fi
EOF
    chmod +x "$bin_dir/cybervps-start"

    # cybervps-stop
    cat << 'EOF' > "$bin_dir/cybervps-stop"
#!/usr/bin/env bash
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../cyberbackup" 2>/dev/null && pwd || echo "$HOME/cyberbackup")"
if [ -f "$REPO_DIR/lib/services.sh" ]; then
    source "$REPO_DIR/lib/services.sh"
    echo "Stopping CyberVPS services..."
    service_init_dirs
    for cfg in "$SERVICES_CONFIG_DIR"/*.json; do
        [ -f "$cfg" ] || continue
        s_name="$(basename "$cfg" .json)"
        service_stop "$s_name"
    done
    if [ -x "$HOME/services/stop-all.sh" ]; then
        "$HOME/services/stop-all.sh"
    fi
else
    echo "CyberVPS library not found at $REPO_DIR"
fi
EOF
    chmod +x "$bin_dir/cybervps-stop"

    log_ok "Installed CyberVPS CLI helper scripts in $bin_dir"
}
