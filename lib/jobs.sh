#!/usr/bin/env bash
# lib/jobs.sh — CyberVPS Persistent Background Job Manager & Service Watchdog
# Manages asynchronous tasks (backups, builds, downloads) that persist independently
# of interactive SSH sessions and client disconnections.

[ -n "${_CYBERVPS_JOBS_SH_LOADED:-}" ] && return 0
_CYBERVPS_JOBS_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=lib/services.sh
source "$LIB_DIR/services.sh"

JOB_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/jobs"
JOB_LOGS_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/logs/jobs"

job_init_dirs() {
    JOB_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/jobs"
    JOB_LOGS_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/logs/jobs"
    ensure_directory "$JOB_STATE_DIR" 0700
    ensure_directory "$JOB_LOGS_DIR" 0755
}

# Check if a job is currently active
job_is_running() {
    local name="$1"
    job_init_dirs
    local pid_file="$JOB_STATE_DIR/${name}.pid"

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

# Run a new background job
job_run() {
    local name="$1"
    shift
    local cmd="$*"

    job_init_dirs

    if [ -z "$cmd" ]; then
        log_error "Usage: cybervps job run <name> <command...>"
        return 1
    fi

    if job_is_running "$name"; then
        log_error "Job '$name' is already running."
        return 1
    fi

    local pid_file="$JOB_STATE_DIR/${name}.pid"
    local meta_file="$JOB_STATE_DIR/${name}.json"
    local log_file="$JOB_LOGS_DIR/${name}.log"

    local now
    now="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date)"

    log_info "Launching background persistent job '$name'..."

    # Execute wrapped job in subshell detached from caller
    (
        nohup bash -c "$cmd" > "$log_file" 2>&1
        local exit_code=$?
        local end_time
        end_time="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date)"
        if [ -f "$meta_file" ]; then
            sed -i "s/\"state\": *\"RUNNING\"/\"state\": \"COMPLETED\"/" "$meta_file" 2>/dev/null || true
            sed -i "s/\"exit_code\": *[0-9-]*/\"exit_code\": $exit_code/" "$meta_file" 2>/dev/null || true
            sed -i "s/\"completed_at\": *\"[^\"]*\"/\"completed_at\": \"$end_time\"/" "$meta_file" 2>/dev/null || true
        fi
        rm -f "$pid_file" 2>/dev/null || true
    ) &
    local pid=$!
    echo "$pid" > "$pid_file"

    local safe_cmd="${cmd//\"/\\\"}"

    cat > "$meta_file" <<EOF
{
  "name": "$name",
  "command": "$safe_cmd",
  "pid": $pid,
  "state": "RUNNING",
  "started_at": "$now",
  "completed_at": "",
  "exit_code": -1,
  "log_file": "$log_file"
}
EOF
    chmod 0600 "$meta_file" 2>/dev/null || true
    log_ok "Job '$name' started in background (PID: $pid)."
}

# List all background jobs
job_list() {
    job_init_dirs
    local found=0

    printf "%-16s %-10s %-8s %-20s %-10s %s\n" "NAME" "STATE" "PID" "STARTED" "EXIT_CODE" "COMMAND"
    printf "%s\n" "----------------------------------------------------------------------------------------------------"

    for meta_file in "$JOB_STATE_DIR"/*.json; do
        [ -f "$meta_file" ] || continue
        found=1
        local j_name j_cmd j_state j_pid j_started j_exit

        j_name="$(grep -o '"name": *"[^"]*"' "$meta_file" 2>/dev/null | cut -d'"' -f4)"
        j_cmd="$(grep -o '"command": *"[^"]*"' "$meta_file" 2>/dev/null | cut -d'"' -f4)"
        j_started="$(grep -o '"started_at": *"[^"]*"' "$meta_file" 2>/dev/null | cut -d'"' -f4 | cut -d'T' -f1)"
        j_exit="$(grep -o '"exit_code": *[0-9-]*' "$meta_file" 2>/dev/null | awk '{print $2}')"

        if job_is_running "$j_name"; then
            j_state="RUNNING"
            j_pid="$(cat "$JOB_STATE_DIR/${j_name}.pid" 2>/dev/null || echo "-")"
        else
            j_state="$(grep -o '"state": *"[^"]*"' "$meta_file" 2>/dev/null | cut -d'"' -f4)"
            [ -z "$j_state" ] && j_state="FINISHED"
            j_pid="-"
        fi

        printf "%-16s %-10s %-8s %-20s %-10s %s\n" "$j_name" "$j_state" "$j_pid" "$j_started" "${j_exit:-0}" "${j_cmd:0:30}"
    done

    if [ "$found" -eq 0 ]; then
        echo "  (No persistent jobs recorded. Run one with: cybervps job run <name> <command...>)"
    fi
}

# Show detailed job status
job_status() {
    local name="$1"
    job_init_dirs
    local meta_file="$JOB_STATE_DIR/${name}.json"

    if [ ! -f "$meta_file" ]; then
        log_error "Job '$name' not found."
        return 1
    fi

    echo "=== CyberVPS Job Status: $name ==="
    cat "$meta_file"
    echo
}

# View job logs
job_logs() {
    local name="$1"
    local lines="${2:-50}"
    job_init_dirs

    local log_file="$JOB_LOGS_DIR/${name}.log"
    if [ -f "$log_file" ]; then
        echo "=== Job Log: $name (last $lines lines) ==="
        tail -n "$lines" "$log_file"
    else
        echo "No log file found for job '$name'."
    fi
}

# Cancel/terminate running job
job_cancel() {
    local name="$1"
    job_init_dirs

    local pid_file="$JOB_STATE_DIR/${name}.pid"
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

    local meta_file="$JOB_STATE_DIR/${name}.json"
    if [ -f "$meta_file" ]; then
        sed -i 's/"state": *"RUNNING"/"state": "CANCELLED"/' "$meta_file" 2>/dev/null || true
    fi

    log_ok "Job '$name' cancelled."
}

# Watchdog routine: supervises registered services and restarts dead ones with exponential backoff
job_watchdog() {
    service_init_dirs
    local checked=0
    local restarted=0

    for cfg in "$SERVICES_CONFIG_DIR"/*.json; do
        [ -f "$cfg" ] || continue
        local s_name s_enabled s_restart s_crashes
        s_name="$(basename "$cfg" .json)"
        s_enabled="$(_service_get_field "$cfg" "enabled" "true")"
        s_restart="$(_service_get_field "$cfg" "restart" "on-failure")"
        s_crashes="$(_service_get_field "$cfg" "crash_count" "0")"

        checked=$((checked + 1))

        if [ "$s_enabled" = "true" ] && [ "$s_restart" != "never" ]; then
            if ! is_service_running "$s_name"; then
                # Apply backoff based on crash count: 1s, 2s, 5s, 10s, 30s, 60s
                local backoff=1
                case "$s_crashes" in
                    0) backoff=1 ;;
                    1) backoff=2 ;;
                    2) backoff=5 ;;
                    3) backoff=10 ;;
                    4) backoff=30 ;;
                    *) backoff=60 ;;
                esac

                log_warn "Service '$s_name' is down. Applying restart backoff (${backoff}s)..."
                sleep "$backoff"

                if service_start "$s_name"; then
                    restarted=$((restarted + 1))
                    log_ok "Watchdog successfully restarted service '$s_name'."
                fi

                # Increment crash count
                local new_crashes=$((s_crashes + 1))
                sed -i "s/\"crash_count\": *[0-9]*/\"crash_count\": $new_crashes/" "$cfg" 2>/dev/null || true
            fi
        fi
    done

    echo "Watchdog check complete: checked $checked service(s), recovered $restarted."
}

# CLI Dispatcher
handle_job_cli() {
    local action="${1:-list}"
    shift || true

    case "$action" in
        run)
            if [ $# -lt 2 ]; then
                echo "Usage: cybervps job run <name> <command...>"
                return 1
            fi
            job_run "$@"
            ;;
        list)
            job_list
            ;;
        status)
            if [ $# -lt 1 ]; then
                echo "Usage: cybervps job status <name>"
                return 1
            fi
            job_status "$1"
            ;;
        logs)
            if [ $# -lt 1 ]; then
                echo "Usage: cybervps job logs <name> [lines]"
                return 1
            fi
            job_logs "$@"
            ;;
        cancel|stop)
            if [ $# -lt 1 ]; then
                echo "Usage: cybervps job cancel <name>"
                return 1
            fi
            job_cancel "$1"
            ;;
        watchdog)
            job_watchdog
            ;;
        help|--help|-h)
            echo "CyberVPS Persistent Job & Watchdog Manager"
            echo "Usage: cybervps job <command> [args...]"
            echo
            echo "Commands:"
            echo "  run <name> <cmd...>   Launch a long-running persistent background task"
            echo "  list                  List all managed jobs"
            echo "  status <name>         Display job state and metadata"
            echo "  logs <name> [lines]   View job output log"
            echo "  cancel <name>         Terminate running job"
            echo "  watchdog              Supervise and auto-recover failed services"
            ;;
        *)
            log_error "Unknown job command: '$action'. Try: cybervps job help"
            return 1
            ;;
    esac
}
