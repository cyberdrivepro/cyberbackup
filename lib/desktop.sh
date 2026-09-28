#!/usr/bin/env bash
# Optional desktop/RDP capability adapter. Defaults to localhost binding and no root login.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/service_backend.sh"
desktop_cli() {
    local action="${1:-doctor}"; shift || true
    case "$action" in
        doctor|status)
            detect_environment
            printf 'Desktop capability: xrdp=%s vnc=%s xfce=%s\n' "${CYBER_XRDP:-false}" "${CYBER_VNC:-false}" "${CYBER_XFCE:-false}"
            printf 'OS service backend: %s\n' "$(service_backend_detect xrdp 2>/dev/null || printf unavailable)"
            ;;
        install)
            detect_environment
            if [ "${CYBERVPS_INSTALL_MODE:-}" = rootless ] || ! cyber_can_admin; then
                printf '%s\n' 'Desktop installation requires authorized root; no privilege escalation is attempted.' >&2
                return 3
            fi
            python3 "$CYBERVPS_ROOT/scripts/desktop_setup.py" install "$@"
            ;;
        configure)
            detect_environment; cyber_can_admin || return 3
            python3 "$CYBERVPS_ROOT/scripts/desktop_setup.py" configure "$@"
            ;;
        start|stop|restart|logs)
            service_backend_action "$action" xrdp
            ;;
        connection)
            detect_environment
            printf 'RDP is local-only by default. Use an authenticated SSH tunnel to 127.0.0.1:3389.\n'
            ;;
        help|--help|-h) printf '%s\n' 'Usage: cybervps desktop {doctor|install|configure|start|stop|restart|status|connection|logs}' ;;
        *) printf 'Unknown desktop action: %s\n' "$action" >&2; return 2 ;;
    esac
}
