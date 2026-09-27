#!/usr/bin/env bash
# lib/logging.sh — Centralized structured logging for CyberVPS
# Provides colored terminal output and persistent log file recording.

# Prevent multiple sourcing
[ -n "${_CYBERVPS_LOGGING_SH_LOADED:-}" ] && return 0
_CYBERVPS_LOGGING_SH_LOADED=1

CYBERVPS_LOG_LEVEL="${CYBERVPS_LOG_LEVEL:-info}" # debug, info, warn, error

# Setup log directory and file
init_logging() {
    local target_dir="${HOME}/.local/state/cybervps/logs"
    if ! mkdir -p "$target_dir" 2>/dev/null; then
        target_dir="${HOME}/logs/cybervps"
        mkdir -p "$target_dir" 2>/dev/null || target_dir="/tmp"
    fi
    CYBERVPS_LOG_FILE="${CYBERVPS_LOG_FILE:-$target_dir/cybervps.log}"
    touch "$CYBERVPS_LOG_FILE" 2>/dev/null || true
}

# Terminal colors (auto-disable if not interactive or NO_COLOR is set)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    CLR_RED='\033[0;31m'
    CLR_GREEN='\033[0;32m'
    CLR_YELLOW='\033[1;33m'
    CLR_BLUE='\033[0;34m'
    CLR_CYAN='\033[0;36m'
    CLR_BOLD='\033[1m'
    CLR_RESET='\033[0m'
else
    CLR_RED=''
    CLR_GREEN=''
    CLR_YELLOW=''
    CLR_BLUE=''
    CLR_CYAN=''
    CLR_BOLD=''
    CLR_RESET=''
fi

_log_timestamp() {
    date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date
}

_write_logfile() {
    local level="$1"
    shift
    if [ -n "${CYBERVPS_LOG_FILE:-}" ] && [ -w "${CYBERVPS_LOG_FILE:-}" ]; then
        printf '[%s] [%-5s] %s\n' "$(_log_timestamp)" "$level" "$*" >> "$CYBERVPS_LOG_FILE" 2>/dev/null || true
    fi
}

log_debug() {
    _write_logfile "DEBUG" "$@"
    if [ "${CYBERVPS_LOG_LEVEL}" = "debug" ]; then
        printf "${CLR_CYAN}[DEBUG]${CLR_RESET} %s\n" "$*" >&2
    fi
}

log_info() {
    _write_logfile "INFO" "$@"
    if [ "${CYBERVPS_LOG_LEVEL}" = "debug" ] || [ "${CYBERVPS_LOG_LEVEL}" = "info" ]; then
        printf "${CLR_BLUE}ℹ${CLR_RESET} %s\n" "$*" >&2
    fi
}

log_ok() {
    _write_logfile "INFO" "[OK] $*"
    printf "${CLR_GREEN}✔${CLR_RESET} %s\n" "$*" >&2
}

log_warn() {
    _write_logfile "WARN" "$@"
    printf "${CLR_YELLOW}⚠${CLR_RESET} %s\n" "$*" >&2
}

log_error() {
    _write_logfile "ERROR" "$@"
    printf "${CLR_RED}✖${CLR_RESET} %s\n" "$*" >&2
}

log_header() {
    _write_logfile "INFO" "=== $* ==="
    printf "\n${CLR_BOLD}%s${CLR_RESET}\n\n" "$*"
}

init_logging
