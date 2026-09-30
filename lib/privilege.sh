#!/usr/bin/env bash
# Canonical privilege classification. Guest UID 0 never grants host authority.
[ -n "${_CYBERVPS_PRIVILEGE_SH_LOADED:-}" ] && return 0
_CYBERVPS_PRIVILEGE_SH_LOADED=1

cyber_probe() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 3 "$@"
    else
        "$@"
    fi
}

detect_container() {
    local root="${CYBERVPS_ROOT_VIEW:-}" proc="${CYBERVPS_PROC_ROOT:-/proc}"
    CYBER_IS_CONTAINER=false
    CYBER_CONTAINER_TYPE=unknown
    if [ -f "$root/.dockerenv" ] || [ -f "$root/run/.containerenv" ]; then
        CYBER_IS_CONTAINER=true
        CYBER_CONTAINER_TYPE=container
    elif [ -n "${container:-}" ]; then
        CYBER_IS_CONTAINER=true
        CYBER_CONTAINER_TYPE="$container"
    elif grep -qsE '(docker|kubepods|containerd|libpod|lxc)' "$proc/1/cgroup"; then
        CYBER_IS_CONTAINER=true
        CYBER_CONTAINER_TYPE=container
    elif [ -z "$root" ] && command -v systemd-detect-virt >/dev/null 2>&1; then
        local found
        if found="$(cyber_probe systemd-detect-virt --container 2>/dev/null)"; then
            CYBER_IS_CONTAINER=true
            CYBER_CONTAINER_TYPE="$found"
        fi
    fi
    CYBER_IS_WSL=false
    if grep -qis microsoft "$proc/sys/kernel/osrelease" 2>/dev/null; then CYBER_IS_WSL=true; fi

    CYBER_PROVIDER_HINT=unknown
    # 1. Explicit configuration
    if [ -n "${CYBERVPS_PROVIDER:-}" ]; then
        case "${CYBERVPS_PROVIDER,,}" in
            daytona) CYBER_PROVIDER_HINT=Daytona; CYBER_IS_CONTAINER=true ;;
            docker) CYBER_PROVIDER_HINT=Docker; CYBER_IS_CONTAINER=true ;;
            k8s|kubernetes) CYBER_PROVIDER_HINT=Kubernetes; CYBER_IS_CONTAINER=true ;;
            wsl) CYBER_PROVIDER_HINT=WSL ;;
            *) CYBER_PROVIDER_HINT="${CYBERVPS_PROVIDER}" ;;
        esac
    fi

    # 2. Check connection profile or config.env
    if [ "$CYBER_PROVIDER_HINT" = "unknown" ]; then
        local cfg="${CYBERVPS_CONFIG_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/cybervps/config.env}"
        if [ -f "$cfg" ]; then
            local p_val
            p_val="$(awk -F= '$1=="CYBERVPS_PROVIDER" {print $2; exit}' "$cfg" 2>/dev/null || true)"
            [ -n "$p_val" ] && CYBER_PROVIDER_HINT="$p_val"
        fi
    fi

    # 3. Environment & marker detection
    if [ "$CYBER_PROVIDER_HINT" = "unknown" ]; then
        if compgen -e 2>/dev/null | grep -q '^DAYTONA_' || [ -d "${root}/var/run/daytona" ] || { [ -z "$root" ] && { [ -d "$HOME/.daytona" ] || command -v daytona >/dev/null 2>&1; }; }; then
            CYBER_PROVIDER_HINT=Daytona
            CYBER_IS_CONTAINER=true
        elif [ -n "${CODESPACES:-}" ] || [ -n "${GITHUB_CODESPACE_TOKEN:-}" ]; then
            CYBER_PROVIDER_HINT="GitHub Codespaces"
            CYBER_IS_CONTAINER=true
        elif [ -n "${GITPOD_WORKSPACE_ID:-}" ]; then
            CYBER_PROVIDER_HINT=Gitpod
            CYBER_IS_CONTAINER=true
        elif [ -n "${REPL_ID:-}" ] || [ -n "${REPLIT_USER:-}" ]; then
            CYBER_PROVIDER_HINT=Replit
            CYBER_IS_CONTAINER=true
        elif [ "$CYBER_IS_WSL" = true ]; then
            CYBER_PROVIDER_HINT=WSL
        elif grep -qsE 'kubepods' "$proc/1/cgroup" 2>/dev/null; then
            CYBER_PROVIDER_HINT=Kubernetes
            CYBER_IS_CONTAINER=true
        elif grep -qsE 'docker' "$proc/1/cgroup" 2>/dev/null || [ -f "$root/.dockerenv" ]; then
            CYBER_PROVIDER_HINT=Docker
            CYBER_IS_CONTAINER=true
        elif grep -qsE 'lxc' "$proc/1/cgroup" 2>/dev/null; then
            CYBER_PROVIDER_HINT=LXC
            CYBER_IS_CONTAINER=true
        elif [ "$CYBER_IS_CONTAINER" = true ]; then
            CYBER_PROVIDER_HINT='Generic Container'
        elif [ "${CYBER_PLATFORM:-Linux}" = "Linux" ]; then
            CYBER_PROVIDER_HINT='Generic VPS'
        fi
    fi
    return 0
}

detect_privilege() {
    CYBER_UID="$(id -u 2>/dev/null || printf unknown)"
    CYBER_IS_ROOT=false
    CYBER_SUDO_NONINTERACTIVE=false
    CYBER_CAN_ADMIN=false
    CYBER_IS_CYBERROOT_GUEST=false
    CYBER_PRIVILEGE_MODE=ROOTLESS
    detect_container
    [ "$CYBER_UID" = 0 ] && CYBER_IS_ROOT=true
    if [ -n "${CYBERROOT_GUEST:-}" ] || [ -n "${CYBERROOT_PREFIX:-}" ]; then
        CYBER_IS_CYBERROOT_GUEST=true
        CYBER_PRIVILEGE_MODE=CYBERROOT_GUEST
    elif [ "$CYBER_IS_ROOT" = true ]; then
        CYBER_CAN_ADMIN=true
        CYBER_PRIVILEGE_MODE=ROOT
        [ "$CYBER_IS_CONTAINER" = true ] && CYBER_PRIVILEGE_MODE=CONTAINER_ROOT
    elif command -v sudo >/dev/null 2>&1 && cyber_probe sudo -n true >/dev/null 2>&1; then
        CYBER_SUDO_NONINTERACTIVE=true
        CYBER_CAN_ADMIN=true
        CYBER_PRIVILEGE_MODE=SUDO_AUTHORIZED
    fi
    return 0
}

cyber_can_admin() {
    detect_privilege
    [ "$CYBER_CAN_ADMIN" = true ]
}

# Revalidate authority at the action boundary; do not trust exported mode values.
cyber_run_privileged() {
    [ "$#" -gt 0 ] || return 2
    detect_privilege
    if [ "$CYBER_CAN_ADMIN" != true ]; then
        printf '%s\n' 'Authorized system administration is unavailable in this environment.' >&2
        return 3
    fi
    if [ "$CYBER_IS_ROOT" = true ]; then
        "$@"
    else
        sudo -n -- "$@"
    fi
}
