#!/usr/bin/env bash
[ -n "${_CYBERVPS_PROCESS_SH_LOADED:-}" ] && return 0
_CYBERVPS_PROCESS_SH_LOADED=1
CYBERVPS_PROCESS_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/process_identity.py"

cyber_validate_name() {
    [[ "${1:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$ ]] || {
        printf 'Invalid resource name: use 1-64 letters, numbers, dash or underscore.\n' >&2
        return 2
    }
}

process_record() {
    python3 "$CYBERVPS_PROCESS_HELPER" record "$2.identity.json" "$1"
}

process_is_owned() {
    python3 "$CYBERVPS_PROCESS_HELPER" alive "$1.identity.json" 2>/dev/null
}

process_stop_owned() {
    python3 "$CYBERVPS_PROCESS_HELPER" stop "$1.identity.json"
}
