#!/usr/bin/env bash
# lib/services.sh — Rootless service management and backend abstraction for CyberVPS
# Supports systemd --user, tmux, screen, and nohup+PID tracking.
# Safe defaults: binds only 127.0.0.1. Compliant with provider restrictions.

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
ensure_directory "$RUN_DIR" 0700
ensure_directory "$LOGS_DIR" 0755
ensure_directory "$CONFIG_DIR" 0700
ensure_directory "$SERVICES_DIR" 0755

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

# Check if a specific service is running
is_service_running() {
    local svc_name="$1"
    local pid_file="$RUN_DIR/${svc_name}.pid"

    if [ -f "$pid_file" ]; then
        local pid
        pid="$(cat "$pid_file" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        # Stale PID file
        rm -f "$pid_file"
    fi

    local backend
    backend="$(get_process_backend)"
    if [ "$backend" = "tmux" ] && have_command tmux; then
        if tmux has-session -t "cybervps-${svc_name}" 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# Start a generic background service
cybervps_service_start() {
    local svc_name="$1"
    shift
    local cmd="$*"

    local pid_file="$RUN_DIR/${svc_name}.pid"
    local log_file="$LOGS_DIR/${svc_name}.log"

    if is_service_running "$svc_name"; then
        log_info "Service '$svc_name' is already running."
        return 0
    fi

    local backend
    backend="$(get_process_backend)"
    log_info "Starting service '$svc_name' using backend [$backend]..."

    case "$backend" in
        tmux)
            local session="cybervps-${svc_name}"
            tmux new-session -d -s "$session" "bash -c '$cmd 2>&1 | tee -a \"$log_file\"'"
            local pid
            pid="$(tmux list-panes -t "$session" -F "#{pane_pid}" 2>/dev/null | head -1 || true)"
            if [ -n "$pid" ]; then
                echo "$pid" > "$pid_file"
            fi
            ;;
        screen)
            local session="cybervps-${svc_name}"
            screen -dmS "$session" bash -c "$cmd 2>&1 | tee -a \"$log_file\""
            ;;
        nohup|*)
            nohup bash -c "$cmd" >> "$log_file" 2>&1 &
            local pid=$!
            echo "$pid" > "$pid_file"
            ;;
    esac

    sleep 1
    if is_service_running "$svc_name"; then
        log_ok "Service '$svc_name' started successfully."
        return 0
    else
        log_error "Service '$svc_name' failed to start or exited immediately. Check logs: $log_file"
        return 1
    fi
}

# Stop a generic background service
cybervps_service_stop() {
    local svc_name="$1"
    local pid_file="$RUN_DIR/${svc_name}.pid"
    local stopped=0

    log_info "Stopping service '$svc_name'..."

    if [ -f "$pid_file" ]; then
        local pid
        pid="$(cat "$pid_file" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
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
        rm -f "$pid_file"
    fi

    local backend
    backend="$(get_process_backend)"
    if [ "$backend" = "tmux" ] && have_command tmux; then
        local session="cybervps-${svc_name}"
        if tmux has-session -t "$session" 2>/dev/null; then
            tmux kill-session -t "$session" 2>/dev/null || true
            stopped=1
        fi
    fi

    if [ "$stopped" -eq 1 ]; then
        log_ok "Service '$svc_name' stopped."
    else
        log_info "Service '$svc_name' was not running."
    fi
    return 0
}

# Restart a service
cybervps_service_restart() {
    local svc_name="$1"
    shift
    cybervps_service_stop "$svc_name"
    sleep 1
    cybervps_service_start "$svc_name" "$@"
}

# Service status
cybervps_service_status() {
    local svc_name="$1"
    if is_service_running "$svc_name"; then
        local pid_file="$RUN_DIR/${svc_name}.pid"
        local pid
        pid="$(cat "$pid_file" 2>/dev/null || echo "session")"
        echo "[RUNNING] $svc_name (PID/Session: $pid)"
        return 0
    else
        echo "[STOPPED] $svc_name"
        return 1
    fi
}

# Manage Login-Triggered Recovery (Phase 10)
# Configures shell profile recovery block idempotently without claiming boot autostart
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
    for pid_f in "$HOME/run"/*.pid; do
        [ -f "$pid_f" ] || continue
        svc="$(basename "$pid_f" .pid)"
        cybervps_service_status "$svc"
    done
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
    # If legacy start script exists on current machine, call safely
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
