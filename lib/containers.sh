#!/usr/bin/env bash
# Docker/Podman workload adapter. It reports daemon capability and never claims VPS persistence.
containers_engine() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then printf docker; return 0; fi
    if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then printf podman; return 0; fi
    return 3
}
containers_cli() {
    local action="${1:-doctor}"; shift || true engine
    case "$action" in
        doctor)
            if engine="$(containers_engine)"; then printf 'Container engine: %s (daemon reachable)\n' "$engine"; else printf '%s\n' 'Container engine: unavailable (CLI, daemon, or authorization missing)'; return 3; fi
            ;;
        list)
            engine="$(containers_engine)" || { printf '%s\n' 'Container listing unavailable.' >&2; return 3; }
            "$engine" ps --all --format '{{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Names}}'
            ;;
        run)
            engine="$(containers_engine)" || return 3
            local name="${1:-}" image="${2:-}"; shift 2 || return 2
            [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ && -n "$image" ]] || return 2
            "$engine" run --detach --name "$name" --label cybervps.managed=true -- "$image" "$@"
            ;;
        stop|logs|inspect)
            engine="$(containers_engine)" || return 3
            local id="${1:-}"; [ -n "$id" ] || return 2
            [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] || return 2
            case "$action" in stop) "$engine" stop -- "$id";; logs) "$engine" logs -- "$id";; inspect) "$engine" inspect -- "$id";; esac
            ;;
        help|--help|-h) printf '%s\n' 'Usage: cybervps containers {doctor|list|run NAME IMAGE [ARGV...]|stop NAME|logs NAME|inspect NAME}' ;;
        *) printf 'Unknown containers action: %s\n' "$action" >&2; return 2 ;;
    esac
}
