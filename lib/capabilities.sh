#!/usr/bin/env bash
# Capabilities distinguish installed commands from operational backends.
[ -n "${_CYBERVPS_CAPABILITIES_SH_LOADED:-}" ] && return 0
_CYBERVPS_CAPABILITIES_SH_LOADED=1

cyber_systemd_system_available() {
    local proc="${CYBERVPS_PROC_ROOT:-/proc}"
    [ "$(cat "$proc/1/comm" 2>/dev/null)" = systemd ] &&
        command -v systemctl >/dev/null 2>&1 &&
        cyber_probe systemctl list-units --no-pager >/dev/null 2>&1
}

cyber_systemd_user_available() {
    command -v systemctl >/dev/null 2>&1 &&
        cyber_probe systemctl --user list-units --no-pager >/dev/null 2>&1
}

detect_capabilities() {
    local command_name
    CYBER_SYSTEMD_SYSTEM=false CYBER_SYSTEMD_USER=false
    cyber_systemd_system_available && CYBER_SYSTEMD_SYSTEM=true
    cyber_systemd_user_available && CYBER_SYSTEMD_USER=true
    CYBER_SERVICE_COMMAND=false
    command -v service >/dev/null 2>&1 && CYBER_SERVICE_COMMAND=true
    CYBER_OPENRC=false
    if command -v rc-status >/dev/null 2>&1 && cyber_probe rc-status >/dev/null 2>&1; then CYBER_OPENRC=true; fi
    CYBER_PACKAGE_MANAGER=''
    local candidates=''
    case "${CYBER_DISTRO_ID:-unknown}" in
        debian|ubuntu|linuxmint|pop|kali|raspbian) candidates='apt-get apt' ;;
        fedora|rhel|centos|rocky|almalinux|ol) candidates='dnf yum' ;;
        alpine) candidates=apk ;;
        arch|manjaro|endeavouros) candidates=pacman ;;
        opensuse*|sles) candidates=zypper ;;
        *) candidates='apt-get dnf yum apk pacman zypper apt' ;;
    esac
    for command_name in $candidates; do
        if command -v "$command_name" >/dev/null 2>&1; then CYBER_PACKAGE_MANAGER="$command_name"; break; fi
    done
    CYBER_SYSTEM_PACKAGES='NOT INSTALLED'
    if [ -n "$CYBER_PACKAGE_MANAGER" ]; then
        CYBER_SYSTEM_PACKAGES=UNAVAILABLE
        [ "${CYBER_CAN_ADMIN:-false}" = true ] && CYBER_SYSTEM_PACKAGES=AVAILABLE
    fi
    CYBER_BACKENDS=()
    if [ "$CYBER_SYSTEMD_SYSTEM" = true ] && [ "${CYBER_CAN_ADMIN:-false}" = true ]; then CYBER_BACKENDS+=(systemd-system); fi
    [ "$CYBER_SYSTEMD_USER" = true ] && CYBER_BACKENDS+=(systemd-user)
    for command_name in tmux screen nohup; do
        command -v "$command_name" >/dev/null 2>&1 && CYBER_BACKENDS+=("$command_name")
    done
    CYBER_DOCKER_CLI=false CYBER_DOCKER_DAEMON=false CYBER_DOCKER_ROOTLESS=UNKNOWN
    if command -v docker >/dev/null 2>&1; then
        CYBER_DOCKER_CLI=true
        if cyber_probe docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
            CYBER_DOCKER_DAEMON=true
            CYBER_DOCKER_ROOTLESS=false
            if cyber_probe docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -q rootless; then CYBER_DOCKER_ROOTLESS=true; fi
        fi
    fi
    CYBER_PODMAN=false
    if command -v podman >/dev/null 2>&1 && cyber_probe podman info >/dev/null 2>&1; then CYBER_PODMAN=true; fi
    CYBER_QEMU=false CYBER_KVM=false CYBER_NESTED_VIRTUALIZATION=UNKNOWN
    CYBER_QEMU_COMMAND=''
    for command_name in qemu-system-x86_64 qemu-system-aarch64; do
        if command -v "$command_name" >/dev/null 2>&1; then CYBER_QEMU=true; CYBER_QEMU_COMMAND="$command_name"; break; fi
    done
    [ -r "${CYBERVPS_ROOT_VIEW:-}/dev/kvm" ] && [ -w "${CYBERVPS_ROOT_VIEW:-}/dev/kvm" ] && CYBER_KVM=true
    CYBER_VM_MODE=UNAVAILABLE
    if [ "$CYBER_QEMU" = true ]; then
        CYBER_VM_MODE=TCG_SOFTWARE
        [ "$CYBER_KVM" = true ] && CYBER_VM_MODE=KVM_CANDIDATE
    fi
    CYBER_X11=false CYBER_WAYLAND=false CYBER_XRDP=false CYBER_VNC=false CYBER_XFCE=false
    [ -n "${DISPLAY:-}" ] && CYBER_X11=true
    [ -n "${WAYLAND_DISPLAY:-}" ] && CYBER_WAYLAND=true
    command -v xrdp >/dev/null 2>&1 && CYBER_XRDP=true
    command -v startxfce4 >/dev/null 2>&1 && CYBER_XFCE=true
    if command -v vncserver >/dev/null 2>&1 || command -v Xvnc >/dev/null 2>&1; then CYBER_VNC=true; fi
    return 0
}

# Status of optional features, without inventing provider/network reachability.
cyber_feature_status() {
    case "${1:-}" in
        system-packages) printf '%s\n' "$CYBER_SYSTEM_PACKAGES" ;;
        systemd-system) [ "$CYBER_SYSTEMD_SYSTEM" = true ] && echo AVAILABLE || echo UNAVAILABLE ;;
        systemd-user) [ "$CYBER_SYSTEMD_USER" = true ] && echo AVAILABLE || echo UNAVAILABLE ;;
        docker)
            if [ "$CYBER_DOCKER_DAEMON" = true ]; then echo AVAILABLE
            elif [ "$CYBER_DOCKER_CLI" = true ]; then echo PARTIAL
            else echo 'NOT INSTALLED'; fi ;;
        vm) [ "$CYBER_QEMU" = true ] && echo PARTIAL || echo 'NOT INSTALLED' ;;
        desktop) [ "$CYBER_XRDP" = true ] || [ "$CYBER_VNC" = true ] && echo PARTIAL || echo 'NOT INSTALLED' ;;
        cyberroot) command -v cyberroot >/dev/null 2>&1 && echo AVAILABLE || echo 'NOT INSTALLED' ;;
        *) echo UNKNOWN ;;
    esac
}

print_capability_summary() {
    printf 'Privilege: %s (uid=%s)\n' "$CYBER_PRIVILEGE_MODE" "$CYBER_UID"
    printf 'Root UID: %s; authorized system administration: %s\n' "$CYBER_IS_ROOT" "$CYBER_CAN_ADMIN"
    printf 'Container: %s; provider hint: %s\n' "$CYBER_IS_CONTAINER" "$CYBER_PROVIDER_HINT"
    printf 'System packages: %s (%s)\n' "$CYBER_SYSTEM_PACKAGES" "${CYBER_PACKAGE_MANAGER:-none}"
    printf 'Systemd system: %s; systemd user: %s; service command installed: %s\n' "$CYBER_SYSTEMD_SYSTEM" "$CYBER_SYSTEMD_USER" "$CYBER_SERVICE_COMMAND"
    printf 'Docker: %s; QEMU: %s; writable /dev/kvm: %s\n' "$(cyber_feature_status docker)" "$CYBER_QEMU" "$CYBER_KVM"
    printf 'Provider lifecycle / volume persistence / public inbound: UNKNOWN\n'
    if [ "$CYBER_IS_CONTAINER" = true ]; then printf 'Host kernel: provider-managed; container root does not grant host root.\n'; fi
}
