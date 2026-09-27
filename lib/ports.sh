#!/usr/bin/env bash
# lib/ports.sh — Dynamic rootless port allocation and management for CyberVPS
# Ensures no collision with other users on shared VPS environments.
# Defaults strictly to localhost (127.0.0.1).

[ -n "${_CYBERVPS_PORTS_SH_LOADED:-}" ] && return 0
_CYBERVPS_PORTS_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"

PORTS_CONFIG_FILE="${HOME}/.config/cybervps/ports.env"

# Check whether a TCP port is in use
is_port_in_use() {
    local port="$1"
    local host="${2:-127.0.0.1}"

    # Try ss first
    if have_command ss; then
        if ss -tln | grep -qE "(:${port}[[:space:]]|:${port}$)"; then
            return 0 # in use
        fi
    fi

    # Try netstat if available
    if have_command netstat; then
        if netstat -tln 2>/dev/null | grep -qE "(:${port}[[:space:]]|:${port}$)"; then
            return 0 # in use
        fi
    fi

    # Bash /dev/tcp test (connecting to active listening port succeeds)
    if (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; then
        exec 3>&- 2>/dev/null || true
        return 0 # in use
    fi

    # Python test if available
    if have_command python3; then
        if python3 -c "import socket; s = socket.socket(); s.connect(('${host}', ${port})); s.close()" 2>/dev/null; then
            return 0 # in use
        fi
    fi

    return 1 # free
}

is_port_free() {
    ! is_port_in_use "$@"
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
    local service_key="$1"
    local default_port="$2"

    ensure_directory "$(dirname "$PORTS_CONFIG_FILE")" 0700
    touch "$PORTS_CONFIG_FILE"

    # Check if already defined in ports.env
    local current_port
    current_port="$(grep -E "^${service_key}=" "$PORTS_CONFIG_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d ' ' || true)"

    local selected_port=""
    if [ -n "$current_port" ] && is_port_free "$current_port"; then
        selected_port="$current_port"
        log_debug "Reusing reserved port for ${service_key}: $selected_port"
    else
        local candidate="${current_port:-$default_port}"
        selected_port="$(find_free_port "$candidate")"
        log_info "Allocated port for ${service_key}: $selected_port (candidate was $candidate)"

        # Update ports.env idempotently
        if grep -qE "^${service_key}=" "$PORTS_CONFIG_FILE" 2>/dev/null; then
            sed -i "s/^${service_key}=.*/${service_key}=${selected_port}/" "$PORTS_CONFIG_FILE"
        else
            printf '%s=%s\n' "$service_key" "$selected_port" >> "$PORTS_CONFIG_FILE"
        fi
    fi

    echo "$selected_port"
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
