#!/usr/bin/env bash
# Noninteractive control-plane routes; optional modules fail explicitly.
cyber_status() {
    detect_environment
    if [ "${1:-}" = --json ]; then
        local key
        for key in ${!CYBER_@}; do export "$key"; done
        CYBERVPS_VERSION="$CYBERVPS_VERSION" python3 - <<'PY'
import json,os
e=os.environ
fields={'privilege':['UID','PRIVILEGE_MODE','IS_ROOT','CAN_ADMIN','SUDO_NONINTERACTIVE'],
        'environment':['PLATFORM','IS_CONTAINER','IS_CYBERROOT_GUEST','PROVIDER_HINT','DISTRO_PRETTY','ARCH'],
        'resources':['NPROC','HOST_NPROC','RAM_TOTAL_MB','RAM_AVAIL_MB','HOST_RAM_TOTAL_MB','CGROUP_VERSION','DISK_FREE_MB','DISK_FSTYPE','DISK_MOUNT','DISK_WRITABLE'],
        'capabilities':['PACKAGE_MANAGER','SYSTEM_PACKAGES','SYSTEMD_SYSTEM','SYSTEMD_USER','SERVICE_COMMAND']}
result={'protocol_version':1,'version':e['CYBERVPS_VERSION']}
for group,keys in fields.items(): result[group]={k.lower():e.get('CYBER_'+k,'UNKNOWN') for k in keys}
print(json.dumps(result,indent=2))
PY
    else
        print_system_summary
    fi
}

cyber_control_cli() {
    local command="${1:-help}"
    shift || true
    case "$command" in
        status) cyber_status "$@" ;;
        doctor)
            case "${1:-}" in
                --export) bash "$CYBERVPS_ROOT/scripts/cybervps-export-diagnostics.sh" ;;
                --network) detect_network; print_network_summary ;;
                *) bash "$CYBERVPS_ROOT/verify.sh" "$@" ;;
            esac ;;
        install) bash "$CYBERVPS_ROOT/fresh-install.sh" "$@" ;;
        auto)
            # shellcheck source=lib/auto.sh
            source "$CYBERVPS_ROOT/lib/auto.sh"
            cyber_auto_install "$@" ;;
        shell|guest)
            # shellcheck source=lib/proot.sh
            source "$CYBERVPS_ROOT/lib/proot.sh"
            cyber_guest_shell "$@" ;;
        host)
            CYBERVPS_HOST_SHELL=1 exec "${SHELL:-/bin/bash}" -l ;;
        apt)
            # shellcheck source=lib/proot.sh
            source "$CYBERVPS_ROOT/lib/proot.sh"
            cyber_guest_apt "$@" ;;
        root) cyberroot_cli "$@" ;;
        vm) source "$CYBERVPS_ROOT/lib/cybervm.sh"; cybervm_cli "$@" ;;
        desktop) source "$CYBERVPS_ROOT/lib/desktop.sh"; desktop_cli "$@" ;;
        containers) source "$CYBERVPS_ROOT/lib/containers.sh"; containers_cli "$@" ;;
        nodes|fleet|files|secret) python3 "$CYBERVPS_ROOT/scripts/fleet_control.py" "$command" "$@" ;;
        provider)
            [ "${1:-}" = daytona ] || { log_error 'Supported provider: daytona'; return 3; }
            shift; python3 "$CYBERVPS_ROOT/scripts/daytona_provider.py" "$@" ;;
        agent|node)
            local binary="${CYBERAGENT_BIN:-cyberagent}"
            command -v "$binary" >/dev/null 2>&1 || { log_error 'CyberAgent is not installed. Build agent/Cargo.toml.'; return 3; }
            "$binary" "$@" ;;
        backup)
            local action="${1:-create}"
            shift || true
            case "$action" in
                create) bash "$CYBERVPS_ROOT/backup-now.sh" "$@" ;;
                restore) bash "$CYBERVPS_ROOT/restore.sh" "$@" ;;
                verify) source "$CYBERVPS_ROOT/lib/restore.sh"; verify_archive_integrity "${1:-}" ;;
                *) return 2 ;;
            esac ;;
        deploy|update|cleanup|schedule) python3 "$CYBERVPS_ROOT/scripts/operations.py" "$command" "$@" ;;
        help|--help|-h)
            printf '%s\n' 'CyberVPS Ultra' 'Usage: cybervps COMMAND [OPTIONS]' \
              'status [--json] | doctor [--json|--network|--export]' \
              'auto [level 1-4] | shell | host | apt [args...]' \
              'install --profile minimal --mode auto --dry-run' \
              'service | session | job | persistence | webterm | tunnel | telegram' \
              'root | vm | desktop | containers | nodes | fleet | files | secret' \
              'provider daytona | agent | backup | deploy | update | cleanup | schedule' ;;
        *) log_error "Unknown command: $command"; return 2 ;;
    esac
}
