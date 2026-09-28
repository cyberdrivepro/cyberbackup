#!/usr/bin/env bash
# lib/ports.sh — Dynamic rootless port allocation and management for CyberVPS
# Ensures no collision with other users on shared VPS environments.
# Defaults strictly to localhost (127.0.0.1).

[ -n "${_CYBERVPS_PORTS_SH_LOADED:-}" ] && return 0
_CYBERVPS_PORTS_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"

PORTS_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/cybervps/ports.env"

# Check whether a TCP port is in use
is_port_in_use() {
    ! is_port_free "$@"
}

is_port_free() {
    python3 "$CYBERVPS_ROOT/scripts/ports_control.py" probe "$1" --host "${2:-127.0.0.1}"
}

# Find a free unprivileged port (range 1024-65535)
find_free_port() {
    local preferred="${1:-8080}"
    local min_port="${2:-1024}"
    local max_port="${3:-49151}"

    # Verify preferred port first
    if [ "$preferred" -ge "$min_port" ] && [ "$preferred" -le "$max_port" ]; then
        if is_port_free "$preferred"; then
            echo "$preferred"
            return 0
        fi
    fi

    # Search for an available port starting from preferred + 1
    local p
    for ((p = preferred + 1; p <= max_port; p++)); do
        if is_port_free "$p"; then
            echo "$p"
            return 0
        fi
    done

    # If not found, search from min_port to preferred
    for ((p = min_port; p < preferred; p++)); do
        if is_port_free "$p"; then
            echo "$p"
            return 0
        fi
    done

    log_error "No free unprivileged port found in range $min_port - $max_port"
    return 1
}

# Allocate or reuse a port for a logical service
# Example: reserve_or_select_port "WEB_PORT" 8080
reserve_or_select_port() {
    python3 "$CYBERVPS_ROOT/scripts/ports_control.py" reserve "$2" --key "$1" --file "$PORTS_CONFIG_FILE"
}

# Load all configured ports into current environment
load_ports_env() {
    if [ -f "$PORTS_CONFIG_FILE" ]; then
        parse_env_file "$PORTS_CONFIG_FILE"
    fi
}

# Initialize ports configuration with safe defaults if not already present
init_ports_config() {
    ensure_directory "$(dirname "$PORTS_CONFIG_FILE")" 0700
    if [ ! -f "$PORTS_CONFIG_FILE" ]; then
        touch "$PORTS_CONFIG_FILE"
    fi
    reserve_or_select_port "WEB_PORT" 8080 >/dev/null 2>&1 || true
    reserve_or_select_port "WEB_PROXY_PORT" 8081 >/dev/null 2>&1 || true
    reserve_or_select_port "REDIS_PORT" 6380 >/dev/null 2>&1 || true
    log_debug "Ports configuration initialized at $PORTS_CONFIG_FILE"
}

# Alias for reserve_or_select_port
get_port() {
    reserve_or_select_port "$@"
}
