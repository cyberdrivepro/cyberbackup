#!/usr/bin/env bash
# lib/sessions.sh — CyberVPS Persistent Terminal & Session Manager
# Rootless persistent session management with support for tmux, screen,
# systemd --user, and nohup+PID fallback.
# Stores session metadata under ${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/sessions/

[ -n "${_CYBERVPS_SESSIONS_SH_LOADED:-}" ] && return 0
_CYBERVPS_SESSIONS_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
source "$LIB_DIR/process.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"

# Ensure session storage directories exist dynamically based on current HOME / XDG_STATE_HOME
session_init_dirs() {
    SESSION_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/sessions"
    SESSION_LOGS_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/logs/sessions"
    ensure_directory "$SESSION_STATE_DIR" 0700
    ensure_directory "$SESSION_LOGS_DIR" 0755
}

# Resolve backend for sessions: systemd-user -> tmux -> screen -> nohup
session_get_backend() {
    local configured="${CYBERVPS_SESSION_BACKEND:-auto}"
    if [ "$configured" != "auto" ]; then
        echo "$configured"
        return 0
    fi

    # For interactive terminal sessions, prefer tmux
    if have_command tmux; then
        echo "tmux"
        return 0
    fi

    if have_command screen; then
        echo "screen"
        return 0
    fi

    if have_command systemctl && systemctl --user list-units >/dev/null 2>&1; then
        echo "systemd-user"
        return 0
    fi

    echo "nohup"
}

# Validate session name format (alphanumeric, dash, underscore only)
session_validate_name() {
    local name="$1"
    cyber_validate_name "$name" || return 2
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid session name '$name'. Must contain only alphanumeric, dash, and underscore."
        return 1
    fi
    return 0
}

# Check if a session is alive
session_is_alive() {
    local name="$1"
    cyber_validate_name "$name" || return 2
    session_init_dirs
    local meta_file="$SESSION_STATE_DIR/${name}.json"
    [ -f "$meta_file" ] || return 1

    local backend
    backend="$(grep -o '"backend": *"[^"]*"' "$meta_file" 2>/dev/null | cut -d'"' -f4 || echo "unknown")"

    case "$backend" in
        tmux)
            have_command tmux && tmux has-session -t "cybervps-${name}" 2>/dev/null
            return $?
            ;;
        screen)
            have_command screen && screen -ls 2>/dev/null | grep -q "cybervps-${name}"
            return $?
            ;;
        nohup|systemd-user)
            local pid
            pid="$(grep -o '"pid": *[0-9]*' "$meta_file" 2>/dev/null | grep -o '[0-9]*' || true)"
            if process_is_owned "$meta_file"; then
                return 0
            fi
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

# Write session metadata JSON
_session_write_meta() {
    local name="$1" backend="$2" cwd="$3" shell_bin="$4" state="$5" pid="$6" tmux_name="$7" cmd="$8" log_file="$9"
    cyber_validate_name "$name" || return 2
    local now
    now="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")"
    local meta_file="$SESSION_STATE_DIR/${name}.json"

    # Escape quotes in command and cwd
    local safe_cmd="${cmd//\"/\\\"}"
    local safe_cwd="${cwd//\"/\\\"}"

    cat > "$meta_file" <<EOF
{
  "name": "$name",
  "backend": "$backend",
  "created_at": "$now",
  "last_started": "$now",
  "working_directory": "$safe_cwd",
  "shell": "$shell_bin",
  "state": "$state",
  "pid": ${pid:-0},
  "tmux_name": "$tmux_name",
  "command": "$safe_cmd",
  "log_file": "$log_file"
}
EOF
    chmod 0600 "$meta_file" 2>/dev/null || true
}

# Create a new persistent session
session_new() {
    local name="$1"
    cyber_validate_name "$name" || return 2
    shift || true
    local cmd="${*:-}"

    session_init_dirs
    session_validate_name "$name" || return 1

    if session_is_alive "$name"; then
        log_error "Session '$name' is already running."
        return 1
    fi

    local backend
    backend="$(session_get_backend)"
    local shell_bin="${SHELL:-/bin/bash}"
    local cwd="$PWD"
    local log_file="$SESSION_LOGS_DIR/${name}.log"
    local tmux_name="cybervps-${name}"
    local target_cmd="${cmd:-$shell_bin}"
    local pid=0

    log_info "Creating session '$name' with backend [$backend]..."

    case "$backend" in
        tmux)
            if [ -n "$cmd" ]; then
                tmux new-session -d -s "$tmux_name" -c "$cwd" "$cmd"
            else
                tmux new-session -d -s "$tmux_name" -c "$cwd" "$shell_bin"
            fi
            pid="$(tmux list-panes -t "$tmux_name" -F '#{pane_pid}' 2>/dev/null | head -n1 || echo 0)"
            ;;
        screen)
            if [ -n "$cmd" ]; then
                screen -dmS "$tmux_name" sh -c "cd '$cwd' && exec $cmd"
            else
                screen -dmS "$tmux_name" sh -c "cd '$cwd' && exec $shell_bin"
            fi
            pid="$(screen -ls | grep "$tmux_name" | awk '{print $1}' | cut -d'.' -f1 | head -n1 || echo 0)"
            ;;
        nohup|*)
            backend="nohup"
            local run_cmd="${cmd:-sleep infinity}"
            (cd "$cwd" && nohup sh -c "$run_cmd" > "$log_file" 2>&1 & echo $! > "$SESSION_STATE_DIR/${name}.pid")
            pid="$(cat "$SESSION_STATE_DIR/${name}.pid" 2>/dev/null || echo 0)"
            rm -f "$SESSION_STATE_DIR/${name}.pid"
            ;;
    esac

    _session_write_meta "$name" "$backend" "$cwd" "$shell_bin" "RUNNING" "$pid" "$tmux_name" "$target_cmd" "$log_file"
    if [ "$backend" = nohup ]; then
        process_record "$pid" "$SESSION_STATE_DIR/${name}.json" || return 8
    fi
    session_is_alive "$name" || { log_error "Session exited during startup."; return 8; }
    log_success "Session '$name' started successfully (backend: $backend, PID: $pid)."
    return 0
}

# List all sessions
session_list() {
    session_init_dirs
    local found=0

    printf "%-16s %-12s %-10s %-8s %-20s %s\n" "NAME" "BACKEND" "STATE" "PID" "CREATED" "COMMAND"
    printf "%s\n" "----------------------------------------------------------------------------------------------------"

    for meta_file in "$SESSION_STATE_DIR"/*.json; do
        [ -f "$meta_file" ] || continue
        found=1
        local s_name s_backend s_created s_pid s_cmd s_state

        s_name="$(grep -o '"name": *"[^"]*"' "$meta_file" 2>/dev/null | cut -d'"' -f4)"
        s_backend="$(grep -o '"backend": *"[^"]*"' "$meta_file" 2>/dev/null | cut -d'"' -f4)"
        s_created="$(grep -o '"created_at": *"[^"]*"' "$meta_file" 2>/dev/null | cut -d'"' -f4 | cut -d'T' -f1)"
        s_pid="$(grep -o '"pid": *[0-9]*' "$meta_file" 2>/dev/null | grep -o '[0-9]*')"
        s_cmd="$(grep -o '"command": *"[^"]*"' "$meta_file" 2>/dev/null | cut -d'"' -f4)"

        if session_is_alive "$s_name"; then
            s_state="RUNNING"
        else
            s_state="STOPPED"
        fi

        printf "%-16s %-12s %-10s %-8s %-20s %s\n" "$s_name" "$s_backend" "$s_state" "${s_pid:-0}" "$s_created" "${s_cmd:0:30}"
    done

    if [ "$found" -eq 0 ]; then
        echo "  (No persistent sessions found. Create one with: cybervps session new <name>)"
    fi
}

# Show detailed session information
session_info() {
    local name="$1"
    cyber_validate_name "$name" || return 2
    session_init_dirs
    local meta_file="$SESSION_STATE_DIR/${name}.json"

    if [ ! -f "$meta_file" ]; then
        log_error "Session '$name' not found."
        return 1
    fi

    echo "=== CyberVPS Session Info: $name ==="
    cat "$meta_file"
    echo
    if session_is_alive "$name"; then
        echo "Status: RUNNING"
    else
        echo "Status: STOPPED"
    fi
}

# Attach to an interactive session
session_attach() {
    local name="$1"
    cyber_validate_name "$name" || return 2
    session_init_dirs

    if ! session_is_alive "$name"; then
        log_error "Session '$name' is not active. Start it first with: cybervps session restart $name"
        return 1
    fi

    local meta_file="$SESSION_STATE_DIR/${name}.json"
    local backend
    backend="$(grep -o '"backend": *"[^"]*"' "$meta_file" 2>/dev/null | cut -d'"' -f4)"

    case "$backend" in
        tmux)
            log_info "Attaching to tmux session 'cybervps-${name}' (Detach with: Ctrl+B then D)..."
            tmux attach-session -t "cybervps-${name}"
            ;;
        screen)
            log_info "Attaching to screen session 'cybervps-${name}' (Detach with: Ctrl+A then D)..."
            screen -r "cybervps-${name}"
            ;;
        *)
            log_error "Backend '$backend' does not support interactive terminal attachment."
            echo "Use 'cybervps session logs $name' to view output."
            return 1
            ;;
    esac
}

# Execute a command in a session
session_exec() {
    local name="$1"
    cyber_validate_name "$name" || return 2
    shift
    local cmd="$*"

    session_init_dirs
    if ! session_is_alive "$name"; then
        log_error "Session '$name' is not running."
        return 1
    fi

    local meta_file="$SESSION_STATE_DIR/${name}.json"
    local backend
    backend="$(grep -o '"backend": *"[^"]*"' "$meta_file" 2>/dev/null | cut -d'"' -f4)"

    case "$backend" in
        tmux)
            tmux send-keys -t "cybervps-${name}" "$cmd" C-m
            log_success "Executed in session '$name': $cmd"
            ;;
        screen)
            screen -S "cybervps-${name}" -X stuff "$cmd$(printf '\r')"
            log_success "Executed in session '$name': $cmd"
            ;;
        *)
            log_error "Backend '$backend' does not support dynamic command execution."
            return 1
            ;;
    esac
}

# Send raw keystrokes / input to a session
session_send() {
    session_exec "$@"
}

# Stop a session
session_stop() {
    local name="$1"
    cyber_validate_name "$name" || return 2
    session_init_dirs

    local meta_file="$SESSION_STATE_DIR/${name}.json"
    if [ ! -f "$meta_file" ]; then
        log_error "Session '$name' not found."
        return 1
    fi

    local backend
    backend="$(grep -o '"backend": *"[^"]*"' "$meta_file" 2>/dev/null | cut -d'"' -f4)"

    log_info "Stopping session '$name'..."

    case "$backend" in
        tmux)
            tmux kill-session -t "cybervps-${name}" 2>/dev/null || true
            ;;
        screen)
            screen -S "cybervps-${name}" -X quit 2>/dev/null || true
            ;;
        nohup|*)
            local pid
            pid="$(grep -o '"pid": *[0-9]*' "$meta_file" 2>/dev/null | grep -o '[0-9]*')"
            if process_is_owned "$meta_file"; then
                process_stop_owned "$meta_file" || return 8
            fi
            ;;
    esac

    # Update state in metadata
    sed -i 's/"state": *"RUNNING"/"state": "STOPPED"/' "$meta_file" 2>/dev/null || true
    log_success "Session '$name' stopped."
    return 0
}

# Restart a session
session_restart() {
    local name="$1"
    cyber_validate_name "$name" || return 2
    session_init_dirs

    local meta_file="$SESSION_STATE_DIR/${name}.json"
    if [ ! -f "$meta_file" ]; then
        log_error "Session '$name' not found."
        return 1
    fi

    local cmd
    cmd="$(grep -o '"command": *"[^"]*"' "$meta_file" 2>/dev/null | cut -d'"' -f4)"

    session_stop "$name"
    sleep 1
    session_new "$name" "$cmd"
}

# Rename a session
session_rename() {
    local old_name="$1"
    local new_name="$2"
    cyber_validate_name "$old_name" || return 2
    cyber_validate_name "$new_name" || return 2
    session_init_dirs

    local old_meta="$SESSION_STATE_DIR/${old_name}.json"
    local new_meta="$SESSION_STATE_DIR/${new_name}.json"

    if [ ! -f "$old_meta" ]; then
        log_error "Session '$old_name' does not exist."
        return 1
    fi
    if [ -f "$new_meta" ]; then
        log_error "Session '$new_name' already exists."
        return 1
    fi

    local backend
    backend="$(grep -o '"backend": *"[^"]*"' "$old_meta" 2>/dev/null | cut -d'"' -f4)"

    if [ "$backend" = "tmux" ] && have_command tmux; then
        tmux rename-session -t "cybervps-${old_name}" "cybervps-${new_name}" 2>/dev/null || true
    fi

    sed -i "s/\"name\": *\"$old_name\"/\"name\": \"$new_name\"/" "$old_meta"
    sed -i "s/cybervps-$old_name/cybervps-$new_name/g" "$old_meta"
    mv "$old_meta" "$new_meta"
    [ -f "${old_meta}.identity.json" ] && mv "${old_meta}.identity.json" "${new_meta}.identity.json"
    [ -f "$SESSION_LOGS_DIR/${old_name}.log" ] && mv "$SESSION_LOGS_DIR/${old_name}.log" "$SESSION_LOGS_DIR/${new_name}.log"

    log_success "Renamed session '$old_name' to '$new_name'."
}

# View session logs or pane history
session_logs() {
    local name="$1"
    cyber_validate_name "$name" || return 2
    local lines="${2:-50}"

    session_init_dirs
    local meta_file="$SESSION_STATE_DIR/${name}.json"
    if [ ! -f "$meta_file" ]; then
        log_error "Session '$name' not found."
        return 1
    fi

    local backend
    backend="$(grep -o '"backend": *"[^"]*"' "$meta_file" 2>/dev/null | cut -d'"' -f4)"

    if [ "$backend" = "tmux" ] && have_command tmux && session_is_alive "$name"; then
        echo "=== Output buffer for tmux session 'cybervps-${name}' (last $lines lines) ==="
        tmux capture-pane -t "cybervps-${name}" -p -S "-$lines" 2>/dev/null | tail -n "$lines"
        return 0
    fi

    local log_file="$SESSION_LOGS_DIR/${name}.log"
    if [ -f "$log_file" ]; then
        echo "=== Session Log: $log_file (last $lines lines) ==="
        tail -n "$lines" "$log_file"
    else
        echo "No log buffer available for session '$name'."
    fi
}

# Kill and permanently remove a session
session_kill() {
    local name="$1"
    cyber_validate_name "$name" || return 2
    session_init_dirs

    session_stop "$name" 2>/dev/null || true
    rm -f "$SESSION_STATE_DIR/${name}.json"
    rm -f "$SESSION_STATE_DIR/${name}.json.identity.json"
    rm -f "$SESSION_LOGS_DIR/${name}.log"
    log_success "Session '$name' killed and metadata removed."
}

# Clean stale / stopped session metadata
session_clean() {
    session_init_dirs
    local count=0

    for meta_file in "$SESSION_STATE_DIR"/*.json; do
        [ -f "$meta_file" ] || continue
        local s_name
        s_name="$(grep -o '"name": *"[^"]*"' "$meta_file" 2>/dev/null | cut -d'"' -f4)"
        if ! session_is_alive "$s_name"; then
            rm -f "$meta_file"
            count=$((count + 1))
        fi
    done

    log_success "Cleaned $count stale session(s)."
}

# CLI Dispatcher
handle_session_cli() {
    local action="${1:-list}"
    shift || true

    case "$action" in
        new)
            if [ $# -lt 1 ]; then
                echo "Usage: cybervps session new <name> [command...]"
                return 1
            fi
            session_new "$@"
            ;;
        list)
            session_list
            ;;
        info)
            if [ $# -lt 1 ]; then
                echo "Usage: cybervps session info <name>"
                return 1
            fi
            session_info "$1"
            ;;
        attach)
            if [ $# -lt 1 ]; then
                echo "Usage: cybervps session attach <name>"
                return 1
            fi
            session_attach "$1"
            ;;
        exec)
            if [ $# -lt 2 ]; then
                echo "Usage: cybervps session exec <name> <command...>"
                return 1
            fi
            session_exec "$@"
            ;;
        send)
            if [ $# -lt 2 ]; then
                echo "Usage: cybervps session send <name> <keys...>"
                return 1
            fi
            session_send "$@"
            ;;
        stop)
            if [ $# -lt 1 ]; then
                echo "Usage: cybervps session stop <name>"
                return 1
            fi
            session_stop "$1"
            ;;
        restart)
            if [ $# -lt 1 ]; then
                echo "Usage: cybervps session restart <name>"
                return 1
            fi
            session_restart "$1"
            ;;
        rename)
            if [ $# -lt 2 ]; then
                echo "Usage: cybervps session rename <old> <new>"
                return 1
            fi
            session_rename "$1" "$2"
            ;;
        logs)
            if [ $# -lt 1 ]; then
                echo "Usage: cybervps session logs <name> [lines]"
                return 1
            fi
            session_logs "$@"
            ;;
        kill)
            if [ $# -lt 1 ]; then
                echo "Usage: cybervps session kill <name>"
                return 1
            fi
            session_kill "$1"
            ;;
        clean)
            session_clean
            ;;
        help|--help|-h)
            echo "CyberVPS Persistent Session Manager"
            echo "Usage: cybervps session <command> [args...]"
            echo
            echo "Commands:"
            echo "  new <name> [cmd...]   Create a new persistent terminal session"
            echo "  list                  List all managed sessions"
            echo "  info <name>           Display session metadata"
            echo "  attach <name>         Attach to an interactive session"
            echo "  exec <name> <cmd...>  Send command to running session"
            echo "  send <name> <keys...> Send keystrokes to running session"
            echo "  stop <name>           Stop a running session"
            echo "  restart <name>        Restart a session"
            echo "  rename <old> <new>    Rename a session"
            echo "  logs <name> [lines]   View session output/history"
            echo "  kill <name>           Kill and remove session metadata"
            echo "  clean                 Clean up inactive session records"
            ;;
        *)
            log_error "Unknown session command: '$action'. Try: cybervps session help"
            return 1
            ;;
    esac
}
