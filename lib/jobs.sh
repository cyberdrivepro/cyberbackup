#!/usr/bin/env bash
[ -n "${_CYBERVPS_JOBS_SH_LOADED:-}" ] && return 0
_CYBERVPS_JOBS_SH_LOADED=1
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/common.sh"; source "$LIB_DIR/process.sh"; source "$LIB_DIR/services.sh"
job_init_dirs() {
    JOB_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/jobs"
    JOB_LOGS_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/logs/jobs"
    ensure_directory "$JOB_STATE_DIR" 0700
    ensure_directory "$JOB_LOGS_DIR" 0755
}
job_is_running() { [ "$#" -eq 1 ] || return 2; cyber_validate_name "$1" || return 2; python3 "$CYBERVPS_RUNTIME_HELPER" job alive "$1"; }
job_run() {
    local name="${1:-}"; shift || return 2; cyber_validate_name "$name" || return 2; [ "$#" -gt 0 ] || return 2
    if [ "$#" -eq 1 ]; then python3 "$CYBERVPS_RUNTIME_HELPER" job run "$name" --shell --cmd "$1" --restart never
    else python3 "$CYBERVPS_RUNTIME_HELPER" job run "$name" --restart never -- "$@"; fi
}
job_list() { python3 "$CYBERVPS_RUNTIME_HELPER" job list "$@"; }
job_status() { python3 "$CYBERVPS_RUNTIME_HELPER" job status "$@"; }
job_cancel() { python3 "$CYBERVPS_RUNTIME_HELPER" job cancel "$@"; }
job_logs() { local name="${1:-}" lines="${2:-50}"; cyber_validate_name "$name" || return 2; job_init_dirs; local file="$JOB_LOGS_DIR/${name}.log"; [ -f "$file" ] && tail -n "$lines" "$file" || printf '%s\n' "No logs for $name"; }
job_watchdog() { printf '%s\n' 'Watchdog: every managed service uses an independent bounded supervisor.'; }
handle_job_cli() {
    local action="${1:-list}"; shift || true
    case "$action" in run) [ "$#" -ge 2 ] || return 2; job_run "$@";; list) job_list;; status) job_status "$@";; logs) job_logs "$@";; cancel|stop) job_cancel "$@";; watchdog) job_watchdog;; help|--help|-h) printf '%s\n' 'CyberVPS Persistent Job Manager' 'Usage: cybervps job {run|list|status|logs|cancel|watchdog}';; *) log_error "Unknown job command: $action"; return 2;; esac
}
