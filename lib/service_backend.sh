#!/usr/bin/env bash
# Operational OS service adapter. User application services use lib/services.sh.
[ -n "${_CYBERVPS_SERVICE_BACKEND_SH_LOADED:-}" ] && return 0
_CYBERVPS_SERVICE_BACKEND_SH_LOADED=1
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"

service_backend_validate() {
    [[ "${1:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.@-]{0,127}$ ]] || return 2
}

service_backend_detect() {
    local name="${1:-}" unit_state
    [ -z "$name" ] || service_backend_validate "$name" || return 2
    if cyber_can_admin && cyber_systemd_system_available; then
        unit_state="$(systemctl show --property=LoadState --value "$name" 2>/dev/null)"
        if [ -z "$name" ] || [ "$unit_state" = loaded ]; then printf 'systemd-system\n'; return 0; fi
    fi
    if cyber_systemd_user_available; then
        unit_state="$(systemctl --user show --property=LoadState --value "$name" 2>/dev/null)"
        if [ -z "$name" ] || [ "$unit_state" = loaded ]; then printf 'systemd-user\n'; return 0; fi
    fi
    if cyber_can_admin && have_command service && [ -n "$name" ] && [ -r "${CYBERVPS_ROOT_VIEW:-}/etc/init.d/$name" ]; then
        printf 'sysv\n'
        return 0
    fi
    printf 'unavailable\n'
    return 3
}

service_backend_action() {
    local action="$1" name="$2" backend="${3:-}"
    service_backend_validate "$name" || return 2
    case "$action" in start|stop|restart|status) ;; *) return 2 ;; esac
    if [ -z "$backend" ]; then backend="$(service_backend_detect "$name")" || return 3; fi
    case "$backend" in
        systemd-system)
            cyber_systemd_system_available || return 3
            if [ "$action" = status ]; then systemctl --no-pager status "$name"
            else cyber_run_privileged systemctl "$action" "$name"; fi
            ;;
        systemd-user)
            cyber_systemd_user_available || return 3
            systemctl --user "$action" "$name"
            ;;
        sysv)
            [ -r "${CYBERVPS_ROOT_VIEW:-}/etc/init.d/$name" ] && have_command service || return 3
            cyber_run_privileged service "$name" "$action"
            ;;
        *) log_error "No operational OS service backend for $name."; return 3 ;;
    esac
}

service_backend_start() { service_backend_action start "$@"; }
service_backend_stop() { service_backend_action stop "$@"; }
service_backend_restart() { service_backend_action restart "$@"; }
service_backend_status() { service_backend_action status "$@"; }

service_backend_logs() {
    local name="$1" backend="${2:-}"
    service_backend_validate "$name" || return 2
    [ -n "$backend" ] || backend="$(service_backend_detect "$name")" || return 3
    case "$backend" in
        systemd-system) journalctl --no-pager -n 100 -u "$name" ;;
        systemd-user) journalctl --user --no-pager -n 100 -u "$name" ;;
        sysv) log_info "SysV does not define one log source for $name; consult the service-specific logs."; return 3 ;;
        *) return 3 ;;
    esac
}
