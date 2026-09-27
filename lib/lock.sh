#!/usr/bin/env bash
# lib/lock.sh — User-space locking mechanism for CyberVPS
# Provides portable flock locking with atomic mkdir fallback, stale lock detection,
# process liveness checking, and automated trap release.

[ -n "${_CYBERVPS_LOCK_SH_LOADED:-}" ] && return 0
_CYBERVPS_LOCK_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/logging.sh
source "$LIB_DIR/logging.sh"

CYBERVPS_LOCKS_DIR="${HOME}/.config/cybervps/locks"
CYBERVPS_LOCK_FD=200
_CYBERVPS_CURRENT_LOCK_DIR=""
_CYBERVPS_CURRENT_LOCK_NAME=""

# Check if command exists
_have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# Acquire user-space exclusive lock
acquire_lock() {
    local lock_name="${1:-cybervps}"
    local timeout="${2:-10}" # seconds
    local lock_dir="$CYBERVPS_LOCKS_DIR"

    [ -d "$lock_dir" ] || mkdir -p "$lock_dir" 2>/dev/null || true

    local lock_file="$lock_dir/${lock_name}.lock"
    local mkdir_lock="$lock_dir/${lock_name}.lockdir"

    if _have_cmd flock; then
        # Open file descriptor for lock
        eval "exec ${CYBERVPS_LOCK_FD}>\"\$lock_file\""
        if flock -w "$timeout" "$CYBERVPS_LOCK_FD"; then
            echo "$$" >&"$CYBERVPS_LOCK_FD" 2>/dev/null || true
            _CYBERVPS_CURRENT_LOCK_NAME="$lock_name"
            log_debug "Acquired lock (flock) for: $lock_name (PID $$)"
            return 0
        else
            log_error "Could not acquire lock for $lock_name after ${timeout}s (flock held by another process)"
            return 1
        fi
    else
        # Atomic mkdir lock fallback with stale detection
        local start_time
        start_time="$(date +%s)"
        while true; do
            if mkdir "$mkdir_lock" 2>/dev/null; then
                echo "$$" > "$mkdir_lock/pid"
                _CYBERVPS_CURRENT_LOCK_DIR="$mkdir_lock"
                _CYBERVPS_CURRENT_LOCK_NAME="$lock_name"
                log_debug "Acquired lock (mkdir) for: $lock_name (PID $$)"
                return 0
            fi

            # Check for stale lock
            if [ -f "$mkdir_lock/pid" ]; then
                local holding_pid
                holding_pid="$(cat "$mkdir_lock/pid" 2>/dev/null || true)"
                if [ -n "$holding_pid" ]; then
                    if ! kill -0 "$holding_pid" 2>/dev/null; then
                        log_warn "Clearing stale lock held by defunct PID: $holding_pid"
                        rm -rf "$mkdir_lock" 2>/dev/null || true
                        continue
                    fi
                fi
            fi

            local now
            now="$(date +%s)"
            if [ $((now - start_time)) -ge "$timeout" ]; then
                log_error "Could not acquire lock for $lock_name after ${timeout}s"
                return 1
            fi
            sleep 1
        done
    fi
}

# Release previously acquired lock
release_lock() {
    local lock_name="${1:-${_CYBERVPS_CURRENT_LOCK_NAME:-cybervps}}"
    local lock_dir="$CYBERVPS_LOCKS_DIR"

    if _have_cmd flock; then
        eval "exec ${CYBERVPS_LOCK_FD}>&-" 2>/dev/null || true
        log_debug "Released lock (flock) for: $lock_name"
    fi

    local mkdir_lock="$lock_dir/${lock_name}.lockdir"
    if [ -d "$mkdir_lock" ]; then
        rm -rf "$mkdir_lock" 2>/dev/null || true
        log_debug "Released lock (mkdir) for: $lock_name"
    fi

    _CYBERVPS_CURRENT_LOCK_DIR=""
    _CYBERVPS_CURRENT_LOCK_NAME=""
    return 0
}

# Execute command block with lock protection
with_lock() {
    local lock_name="$1"
    shift
    local timeout=10

    if ! acquire_lock "$lock_name" "$timeout"; then
        log_error "Operation failed: lock acquisition timed out for '$lock_name'"
        return 1
    fi

    local rc=0
    "$@" || rc=$?

    release_lock "$lock_name"
    return "$rc"
}
