#!/usr/bin/env bash
# lib/common.sh — Core utility library for CyberVPS
# Provides portable error handling, locking, downloads, config parsing, and file utilities.

[ -n "${_CYBERVPS_COMMON_SH_LOADED:-}" ] && return 0
_CYBERVPS_COMMON_SH_LOADED=1

# Windows App Execution Aliases sometimes expose a non-functional python3
# placeholder. Prefer a working interpreter while retaining the Linux command.
if command -v python3 >/dev/null 2>&1; then
    if ! python3 -c 'import sys' >/dev/null 2>&1 && command -v python >/dev/null 2>&1 && python -c 'import sys' >/dev/null 2>&1; then
        python3() { command python "$@"; }
    fi
elif command -v python >/dev/null 2>&1 && python -c 'import sys' >/dev/null 2>&1; then
    python3() { command python "$@"; }
fi

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/logging.sh
source "$LIB_DIR/logging.sh"

CYBERVPS_ROOT="$(cd "$LIB_DIR/.." && pwd)"
CYBERVPS_VERSION="$(cat "$CYBERVPS_ROOT/VERSION" 2>/dev/null || echo "1.0.0")"
CYBERVPS_BACKUP_FORMAT=2

# Check command existence
have_command() {
    command -v "$1" >/dev/null 2>&1
}

# Ensure directory exists with user-only permissions if requested
ensure_directory() {
    local dir="$1"
    local mode="${2:-0755}"
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        chmod "$mode" "$dir" 2>/dev/null || true
    fi
}

# Verify sha256 checksum of a file
verify_sha256() {
    local file="$1"
    local expected="$2"
    if [ ! -f "$file" ]; then
        log_error "File not found for checksum check: $file"
        return 1
    fi
    local actual
    if have_command sha256sum; then
        actual="$(sha256sum "$file" | awk '{print $1}')"
    elif have_command shasum; then
        actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    elif have_command openssl; then
        actual="$(openssl dgst -sha256 "$file" | awk '{print $NF}')"
    else
        log_warn "No sha256 calculation utility found (sha256sum, shasum, openssl)"
        return 2
    fi

    if [ "$actual" = "$expected" ]; then
        log_debug "SHA256 verified for $file ($actual)"
        return 0
    else
        log_error "SHA256 mismatch for $file! Expected: $expected, Got: $actual"
        return 1
    fi
}

# Download compatibility entrypoint; all callers use the same verified HTTPS engine.
download_file() {
    # shellcheck source=lib/download.sh
    source "$CYBERVPS_ROOT/lib/download.sh"
    cyber_download "$@"
}
# shellcheck source=lib/lock.sh
source "$LIB_DIR/lock.sh"
# shellcheck source=lib/architecture.sh
source "$LIB_DIR/architecture.sh"

# Constrained KEY=VALUE parser (does not eval untrusted shell code)
parse_env_file() {
    local file="$1"
    [ ! -f "$file" ] && return 0

    while IFS= read -r line || [ -n "$line" ]; do
        # Strip leading whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        # Match KEY=VALUE (alphanumeric and underscore keys only)
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"
            # Strip surrounding quotes if present
            if [[ "$val" =~ ^\"(.*)\"$ ]]; then
                val="${BASH_REMATCH[1]}"
            elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
                val="${BASH_REMATCH[1]}"
            fi
            # Restrict export to CYBERVPS_* or known port/service keys
            case "$key" in
                CYBERVPS_*|WEBTERM_USER|WEBTERM_PASS|WEB_TERMINAL_PORT|CYBERROOT_SSH_PORT|CYBERVM_SSH_PORT|RDP_PORT|WEB_PORT|WEB_PROXY_PORT|REDIS_PORT|FASTAPI_PORT|NODE_PORT|CONDA_ENV)
                    export "$key=$val"
                    ;;
                *)
                    log_debug "Ignoring unrecognized config key: $key"
                    ;;
            esac
        fi
    done < "$file"
}

# Atomic file update
atomic_write() {
    local target="$1"
    local content="$2"
    local dir
    dir="$(dirname "$target")"
    ensure_directory "$dir"

    local tmp="${target}.tmp.$$"
    printf '%s\n' "$content" > "$tmp"
    mv -f "$tmp" "$target"
}

# Idempotent marked block management in config files
# Example: # >>> CYBERVPS LOGIN RECOVERY >>> ... # <<< CYBERVPS LOGIN RECOVERY <<<
ensure_marked_block() {
    local target_file="$1"
    local tag="$2"
    local block_content="$3"

    local start_marker="# >>> CYBERVPS ${tag} >>>"
    local end_marker="# <<< CYBERVPS ${tag} <<<"

    ensure_directory "$(dirname "$target_file")"
    touch "$target_file"

    local tmp_file="${target_file}.tmp.$$"
    local in_block=0
    local replaced=0

    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "$start_marker" ]; then
            in_block=1
            printf '%s\n' "$start_marker" >> "$tmp_file"
            printf '%s\n' "$block_content" >> "$tmp_file"
            printf '%s\n' "$end_marker" >> "$tmp_file"
            replaced=1
            continue
        fi
        if [ "$line" = "$end_marker" ]; then
            in_block=0
            continue
        fi
        if [ "$in_block" -eq 0 ]; then
            printf '%s\n' "$line" >> "$tmp_file"
        fi
    done < "$target_file"

    if [ "$replaced" -eq 0 ]; then
        # Append if not previously present
        {
            printf '\n%s\n' "$start_marker"
            printf '%s\n' "$block_content"
            printf '%s\n' "$end_marker"
        } >> "$tmp_file"
    fi

    mv -f "$tmp_file" "$target_file"
    log_debug "Updated marked block '${tag}' in $target_file"
}

remove_marked_block() {
    local target_file="$1"
    local tag="$2"
    [ ! -f "$target_file" ] && return 0

    local start_marker="# >>> CYBERVPS ${tag} >>>"
    local end_marker="# <<< CYBERVPS ${tag} <<<"

    local tmp_file="${target_file}.tmp.$$"
    local in_block=0

    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "$start_marker" ]; then
            in_block=1
            continue
        fi
        if [ "$line" = "$end_marker" ]; then
            in_block=0
            continue
        fi
        if [ "$in_block" -eq 0 ]; then
            printf '%s\n' "$line" >> "$tmp_file"
        fi
    done < "$target_file"

    mv -f "$tmp_file" "$target_file"
    log_debug "Removed marked block '${tag}' from $target_file"
}

# Auto-load user configuration if available
CYBERVPS_CONFIG_FILE="${CYBERVPS_CONFIG_FILE:-$HOME/.config/cybervps/config.env}"
if [ -f "$CYBERVPS_CONFIG_FILE" ]; then
    parse_env_file "$CYBERVPS_CONFIG_FILE"
fi
