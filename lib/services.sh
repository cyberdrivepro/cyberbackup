#!/usr/bin/env bash
[ -n "${_CYBERVPS_SERVICES_SH_LOADED:-}" ] && return 0
_CYBERVPS_SERVICES_SH_LOADED=1
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/common.sh"
source "$LIB_DIR/process.sh"
source "$LIB_DIR/detect.sh"
CYBERVPS_RUNTIME_HELPER="$CYBERVPS_ROOT/scripts/runtime_control.py"
RUN_DIR="${HOME}/run"; LOGS_DIR="${HOME}/logs"; CONFIG_DIR="${HOME}/config"; SERVICES_DIR="${HOME}/services"
service_init_dirs() {
    SERVICES_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cybervps/services"
    SERVICES_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/services"
    SERVICES_LOGS_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/logs/services"
    ensure_directory "$RUN_DIR" 0700; ensure_directory "$LOGS_DIR" 0755; ensure_directory "$CONFIG_DIR" 0700
    ensure_directory "$SERVICES_DIR" 0755; ensure_directory "$SERVICES_CONFIG_DIR" 0700
    ensure_directory "$SERVICES_STATE_DIR" 0700; ensure_directory "$SERVICES_LOGS_DIR" 0755
}
get_process_backend() { printf '%s\n' supervisor; }
service_validate_name() { cyber_validate_name "$1"; }
_service_get_field() {
    python3 - "$1" "$2" "${3:-}" <<'PY'
import json,sys
try:
    value=json.load(open(sys.argv[1],encoding='utf-8')).get(sys.argv[2],sys.argv[3])
    print(str(value).lower() if isinstance(value,bool) else value)
except (OSError,ValueError,TypeError): print(sys.argv[3])
PY
}
is_service_running() { [ "$#" -eq 1 ] || return 2; cyber_validate_name "$1" || return 2; python3 "$CYBERVPS_RUNTIME_HELPER" service alive "$1"; }
service_add() { [ "$#" -ge 1 ] || return 2; cyber_validate_name "$1" || return 2; python3 "$CYBERVPS_RUNTIME_HELPER" service add "$@"; }
service_remove() { python3 "$CYBERVPS_RUNTIME_HELPER" service remove "$@"; }
service_list() { python3 "$CYBERVPS_RUNTIME_HELPER" service list "$@"; }
service_info() { python3 "$CYBERVPS_RUNTIME_HELPER" service info "$@"; }
service_start() { python3 "$CYBERVPS_RUNTIME_HELPER" service start "$@"; }
service_stop() { python3 "$CYBERVPS_RUNTIME_HELPER" service stop "$@"; }
service_restart() { python3 "$CYBERVPS_RUNTIME_HELPER" service restart "$@"; }
service_reload() { python3 "$CYBERVPS_RUNTIME_HELPER" service reload "$@"; }
service_status() { python3 "$CYBERVPS_RUNTIME_HELPER" service status "$@"; }
service_health() { python3 "$CYBERVPS_RUNTIME_HELPER" service health "$@"; }
service_enable() { python3 "$CYBERVPS_RUNTIME_HELPER" service enable "$@"; }
service_disable() { python3 "$CYBERVPS_RUNTIME_HELPER" service disable "$@"; }
service_logs() {
    local name="${1:-}" lines=50 follow=0; cyber_validate_name "$name" || return 2; shift
    while [ "$#" -gt 0 ]; do case "$1" in --lines|-n) [ "$#" -ge 2 ] || return 2; lines="$2"; shift 2;; --follow|-f) follow=1; shift;; *) shift;; esac; done
    service_init_dirs; local files=("$SERVICES_LOGS_DIR/${name}.stdout.log" "$SERVICES_LOGS_DIR/${name}.stderr.log") file
    if [ "$follow" -eq 1 ]; then tail -n "$lines" -f "${files[@]}" 2>/dev/null; return $?; fi
    for file in "${files[@]}"; do [ -f "$file" ] || continue; printf '%s\n' "--- $(basename "$file") ---"; tail -n "$lines" "$file"; done
}
handle_service_cli() {
    local action="${1:-list}"; shift || true
    case "$action" in
        add) service_add "$@";; remove|rm) service_remove "$@";; list) service_list "$@";; info) service_info "$@";;
        start) service_start "$@";; stop) service_stop "$@";; restart) service_restart "$@";; reload) service_reload "$@";;
        status) service_status "$@";; health) service_health "$@";; logs) service_logs "$@";; enable) service_enable "$@";; disable) service_disable "$@";;
        help|--help|-h) printf '%s\n' 'Usage: cybervps service {add|remove|list|start|stop|restart|status|health|logs|enable|disable}';;
        *) log_error "Unknown service command: $action"; return 2;;
    esac
}
cybervps_service_start() { service_start "$@"; }; cybervps_service_stop() { service_stop "$@"; }
cybervps_service_restart() { service_restart "$@"; }; cybervps_service_status() { service_status "$@"; }
setup_login_recovery() {
    local target="${HOME}/.bashrc" helper="${HOME}/bin/cybervps-start"; ensure_directory "${HOME}/bin" 0700
    printf '%s\n' '#!/usr/bin/env bash' "exec bash \"$CYBERVPS_ROOT/cybervps.sh\" service list >/dev/null 2>&1" > "$helper"; chmod 0700 "$helper"
    ensure_marked_block "$target" 'LOGIN RECOVERY' "if [ -x '$helper' ]; then '$helper' >/dev/null 2>&1 || true; fi"
}
disable_login_recovery() { remove_marked_block "${HOME}/.bashrc" 'LOGIN RECOVERY'; }
install_service_cli_helpers() {
    ensure_directory "${HOME}/bin" 0755
    local root="${CYBERVPS_ROOT:-${CYBERVPS_DIR:-$HOME/cyberbackup}}"
    cat << 'EOF' > "${HOME}/bin/cybervps-status"
#!/usr/bin/env bash
exec bash "${CYBERVPS_ROOT:-$HOME/cyberbackup}/cybervps.sh" status "$@"
EOF
    chmod 0755 "${HOME}/bin/cybervps-status"

    cat << 'EOF' > "${HOME}/bin/cybervps-start"
#!/usr/bin/env bash
exec bash "${CYBERVPS_ROOT:-$HOME/cyberbackup}/cybervps.sh" service start "$@"
EOF
    chmod 0755 "${HOME}/bin/cybervps-start"

    cat << 'EOF' > "${HOME}/bin/cybervps-stop"
#!/usr/bin/env bash
exec bash "${CYBERVPS_ROOT:-$HOME/cyberbackup}/cybervps.sh" service stop "$@"
EOF
    chmod 0755 "${HOME}/bin/cybervps-stop"

    setup_login_recovery
    return 0
}
