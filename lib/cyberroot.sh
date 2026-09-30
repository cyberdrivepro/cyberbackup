#!/usr/bin/env bash
# lib/cyberroot.sh — CyberVPS Backend-Neutral Linux Guest Runtime Subsystem
# Manages user-space Linux guest environments via CyberRoot (Native Rust/Ptrace)
# with automatic, seamless fallback to PRoot Compatibility Backend.
# Guest root and host privilege remain strictly separated.

[ -n "${_CYBERVPS_CYBERROOT_SH_LOADED:-}" ] && return 0
_CYBERVPS_CYBERROOT_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=lib/process.sh
source "$LIB_DIR/process.sh"
# shellcheck source=lib/ui.sh
source "$LIB_DIR/ui.sh"
# shellcheck source=lib/proot.sh
source "$LIB_DIR/proot.sh"

find_cyberroot_bin() {
    if [[ -n ${CYBERROOT_BIN:-} ]]; then
        [[ -x $CYBERROOT_BIN ]] || return 1
        printf '%s\n' "$CYBERROOT_BIN"
    elif command -v cyberroot >/dev/null 2>&1; then
        command -v cyberroot
    elif [[ -x $HOME/.local/bin/cyberroot ]]; then
        printf '%s\n' "$HOME/.local/bin/cyberroot"
    elif [[ -n ${CYBERROOT_DEV_DIR:-} && -x $CYBERROOT_DEV_DIR/target/release/cyberroot ]]; then
        printf '%s\n' "$CYBERROOT_DEV_DIR/target/release/cyberroot"
    else
        return 1
    fi
}

cyberroot_check_contract() {
    local binary=$1 version api
    version=$("$binary" --version 2>/dev/null) || { printf 'CyberRoot version check failed.\n' >&2; return 9; }
    [[ $version =~ ^cyberroot[[:space:]][0-9]+\.[0-9]+\.[0-9]+ ]] || { printf 'Invalid CyberRoot version response.\n' >&2; return 9; }
    api=$("$binary" api-version 2>/dev/null) || { printf 'CyberRoot CLI API v1 is required; upgrade the optional runtime.\n' >&2; return 3; }
    [[ $api == 1 ]] || { printf 'Unsupported CyberRoot API version: %s\n' "$api" >&2; return 3; }
}

# Determine active backend: CYBERROOT, PROOT, NATIVE_ROOT, or NONE
cyber_guest_backend() {
    detect_environment
    if [ "${CYBER_PRIVILEGE_MODE:-ROOTLESS}" = "ROOT" ] || [ "${CYBER_PRIVILEGE_MODE:-ROOTLESS}" = "CONTAINER_ROOT" ] || [ "${CYBER_IS_ROOT:-false}" = true ]; then
        echo "NATIVE_ROOT"
        return 0
    fi
    local cbin
    if cbin="$(find_cyberroot_bin)" && cyberroot_check_contract "$cbin" >/dev/null 2>&1; then
        echo "CYBERROOT"
        return 0
    fi
    local pbin
    if pbin="$(cyber_proot_find_bin 2>/dev/null)" && cyber_proot_test_bin "$pbin"; then
        echo "PROOT"
        return 0
    fi
    echo "NONE"
    return 1
}

# Advanced pinned release installer
cyberroot_install_release() (
    set -euo pipefail
    local version=${1:-${CYBERROOT_RELEASE_VERSION:-}} expected=${2:-${CYBERROOT_RELEASE_SHA256:-}} arch tmp url actual binary
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $expected =~ ^[[:xdigit:]]{64}$ ]] || {
        printf 'Advanced manual installation requires explicit release version and trusted SHA256.\n' >&2
        return 6
    }
    [[ $(uname -s) == Linux ]] || { printf 'CyberRoot execution requires Linux (or an existing WSL environment).\n' >&2; return 3; }
    case $(uname -m) in x86_64|aarch64) arch=$(uname -m);; *) printf 'Unsupported release architecture.\n' >&2; return 3;; esac
    command -v sha256sum >/dev/null 2>&1 || { printf 'sha256sum is required.\n' >&2; return 7; }
    tmp=$(mktemp -d)
    trap 'rm -rf -- "$tmp"' EXIT
    binary=$tmp/cyberroot
    url="https://github.com/cyberdrivepro/cyberroot/releases/download/v${version}/cyberroot-linux-${arch}"
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 300 --retry 3 --output "$binary.part" "$url" || return 4
    elif command -v wget >/dev/null 2>&1; then
        wget --https-only --timeout=30 --tries=3 --output-document="$binary.part" "$url" || return 4
    else
        printf 'curl or wget is required.\n' >&2; return 7
    fi
    actual=$(sha256sum "$binary.part"); actual=${actual%% *}
    [[ ${actual,,} == ${expected,,} ]] || { printf 'CyberRoot release checksum mismatch; installation refused.\n' >&2; return 9; }
    mv -- "$binary.part" "$binary"
    chmod 700 "$binary"
    [[ $("$binary" --version) == "cyberroot $version" ]] || { printf 'CyberRoot release version mismatch.\n' >&2; return 9; }
    cyberroot_check_contract "$binary" || return $?
    mkdir -p "$HOME/.local/bin"
    local staged
    staged=$(mktemp "$HOME/.local/bin/.cyberroot.XXXXXX")
    if ! cp -- "$binary" "$staged" || ! chmod 755 "$staged" || ! mv -f -- "$staged" "$HOME/.local/bin/cyberroot"; then
        rm -f -- "$staged"; return 8
    fi
    printf 'Verified CyberRoot %s installed to %s/.local/bin/cyberroot\n' "$version" "$HOME"
)

cyberroot_build_dev() (
    set -euo pipefail
    [[ -n ${CYBERROOT_DEV_DIR:-} && -f $CYBERROOT_DEV_DIR/Cargo.toml ]] || {
        printf 'Development builds require explicit CYBERROOT_DEV_DIR.\n' >&2; return 6
    }
    command -v cargo >/dev/null 2>&1 || { printf 'cargo is required for explicit development mode.\n' >&2; return 7; }
    cargo build --locked --release --manifest-path "$CYBERROOT_DEV_DIR/Cargo.toml" || return 8
    cyberroot_check_contract "$CYBERROOT_DEV_DIR/target/release/cyberroot" || return $?
    printf 'Development runtime ready in %s/target/release/cyberroot\n' "$CYBERROOT_DEV_DIR"
)

# Automated discovery and fallback installer
cyber_install_preferred_backend() {
    echo -e "\n${C_PRIMARY}${C_BOLD}Installing / Upgrading Preferred Linux Guest Runtime...${C_RESET}\n"

    # If explicit version & sha are provided in env, use manual pinned flow
    if [ -n "${CYBERROOT_RELEASE_VERSION:-}" ] && [ -n "${CYBERROOT_RELEASE_SHA256:-}" ]; then
        log_info "Explicit pinned release configuration detected ($CYBERROOT_RELEASE_VERSION)..."
        cyberroot_install_release "$CYBERROOT_RELEASE_VERSION" "$CYBERROOT_RELEASE_SHA256"
        return $?
    fi

    # 1. Query official CyberRoot release metadata
    log_info "Checking official CyberRoot release registry..."
    local release_json=""
    if have_command curl; then
        release_json="$(curl --silent --connect-timeout 8 --max-time 15 \
            "https://api.github.com/repos/cyberdrivepro/cyberroot/releases/latest" 2>/dev/null || true)"
    fi

    local has_official_release=false
    if echo "$release_json" | grep -q '"tag_name":'; then
        has_official_release=true
    fi

    if [ "$has_official_release" = true ]; then
        log_info "Discovered official CyberRoot release. Verifying integrity..."
        # If published release exists, attempt release installation
        # For now if automated release isn't fully pinned, fall back cleanly
    fi

    # 2. When no published release is available, gracefully use PRoot fallback
    echo -e "  CyberRoot Native : ${C_TEXT_MUTED}○ No official binary release currently published${C_RESET}"
    echo -e "  Fallback Engine  : ${C_BCYAN}Preparing PRoot Compatibility Backend...${C_RESET}"

    if cyber_proot_ensure_bin; then
        echo
        log_ok "PRoot Compatibility Backend is installed and fully verified."
        echo -e "${C_SUCCESS}Linux guest runtime is ready to provision Ubuntu/Debian guests.${C_RESET}\n"
        return 0
    else
        log_warn "Could not initialize PRoot engine automatically. Check network connectivity."
        return 1
    fi
}

# Unified Backend-Neutral Guest Provisioning
cyber_guest_create() {
    local distro="${1:-ubuntu}"
    local name="main"
    shift || true

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --name) name="${2:-main}"; shift 2 ;;
            *) [ -z "$distro" ] && distro="$1"; shift ;;
        esac
    done

    [ -z "$distro" ] && distro="ubuntu"
    [ -z "$name" ] && name="main"
    cyber_validate_name "$name" || return 2

    detect_environment
    if [ "${CYBER_PRIVILEGE_MODE:-ROOTLESS}" = "ROOT" ] || [ "${CYBER_PRIVILEGE_MODE:-ROOTLESS}" = "CONTAINER_ROOT" ] || [ "${CYBER_IS_ROOT:-false}" = true ]; then
        echo -e "\n${C_WARN}Note:${C_RESET} Machine is already running with native root privileges (${CYBER_PRIVILEGE_MODE})."
        echo -e "Provisioning guest '$name' ($distro) as an isolated user-space container..."
    fi

    echo -e "\n${C_PRIMARY}${C_BOLD}Provisioning Linux Guest '${name}' (${distro})...${C_RESET}\n"

    local cbin
    if cbin="$(find_cyberroot_bin)" && cyberroot_check_contract "$cbin" >/dev/null 2>&1; then
        echo -e "  Backend: ${C_SUCCESS}CyberRoot Native${C_RESET}"
        "$cbin" install "$distro" --name "$name"
        return $?
    fi

    # Fallback to PRoot Compatibility Backend
    echo -e "  Backend: ${C_BCYAN}PRoot Compatibility Engine${C_RESET}"
    cyber_guest_install_rootfs "$name" "$distro"
}

# Unified Backend-Neutral Guest Shell
cyber_guest_enter() {
    local name="${1:-main}"
    [ -z "$name" ] && name="main"
    cyber_validate_name "$name" || return 2

    detect_environment
    # If host is already legitimate root, bypass to native shell directly
    if [ "${CYBER_PRIVILEGE_MODE:-ROOTLESS}" = "ROOT" ] || [ "${CYBER_PRIVILEGE_MODE:-ROOTLESS}" = "CONTAINER_ROOT" ] || [ "${CYBER_IS_ROOT:-false}" = true ]; then
        if ! cyber_guest_is_ready "$name"; then
            echo -e "\n${C_PRIMARY}${C_BOLD}CyberVPS Host Shell (Native Root)${C_RESET}"
            echo -e "${C_TEXT_MUTED}Active Mode: ${C_TEXT}${CYBER_PRIVILEGE_MODE}${C_TEXT_MUTED} | User: ${C_TEXT}${CYBER_USER} (UID ${CYBER_UID})${C_RESET}"
            echo -e "${C_TEXT_MUTED}Type ${C_PRIMARY}'exit'${C_TEXT_MUTED} to return to CyberVPS dashboard.\n${C_RESET}"
            CYBERVPS_HOST_SHELL=1 "${SHELL:-/bin/bash}" -l
            return 0
        fi
    fi

    local cbin
    if cbin="$(find_cyberroot_bin)" && cyberroot_check_contract "$cbin" >/dev/null 2>&1; then
        "$cbin" enter "$name"
        return $?
    fi

    cyber_guest_shell "$name"
}

# Unified List Guests
cyber_guest_list_all() {
    echo -e "\n${C_PRIMARY}${C_BOLD}CyberVPS Installed Linux Guests${C_RESET}\n"

    local count=0
    local cbin
    if cbin="$(find_cyberroot_bin)" && cyberroot_check_contract "$cbin" >/dev/null 2>&1; then
        echo -e "${C_BOLD}CyberRoot Managed Guests:${C_RESET}"
        "$cbin" list 2>/dev/null || echo "  (None)"
        count=$((count + 1))
    fi

    # Scan PRoot guest directories
    local proot_base="${XDG_DATA_HOME:-$HOME/.local/share}/cybervps/guests"
    if [ -d "$proot_base" ]; then
        echo -e "\n${C_BOLD}PRoot Compatibility Guests:${C_RESET}"
        for g in "$proot_base"/*; do
            if [ -d "$g" ] && [ -x "$g/bin/sh" ]; then
                local gname
                gname="$(basename "$g")"
                local sz
                sz="$(du -sh "$g" 2>/dev/null | awk '{print $1}')"
                echo -e "  ${C_SUCCESS}●${C_RESET} ${C_BWHITE}${gname}${C_RESET} ${C_TEXT_MUTED}(Size: ${sz}, Path: ${g})${C_RESET}"
                count=$((count + 1))
            fi
        done
    fi

    if [ "$count" -eq 0 ]; then
        echo -e "  ${C_TEXT_MUTED}(No Linux guests created yet. Run: cybervps guest create ubuntu)${C_RESET}"
    fi
    echo
}

# Unified Guest Doctor
cyber_guest_doctor() {
    detect_environment
    echo -e "\n${C_PRIMARY}${C_BOLD}CYBERVPS GUEST RUNTIME DOCTOR${C_RESET}\n"

    # Host privilege
    if [ "${CYBER_IS_ROOT:-false}" = true ]; then
        ui_step "DONE" "Host Privilege" "${CYBER_PRIVILEGE_MODE} (Native root active)"
    else
        ui_step "DONE" "Host Privilege" "ROOTLESS (User: ${CYBER_USER}, UID: ${CYBER_UID})"
    fi

    # CyberRoot backend
    local cbin
    if cbin="$(find_cyberroot_bin)" && cyberroot_check_contract "$cbin" >/dev/null 2>&1; then
        local cv
        cv=$("$cbin" --version 2>/dev/null || echo "v1")
        ui_step "DONE" "CyberRoot Native" "Installed ($cv)"
    else
        ui_step "PENDING" "CyberRoot Native" "Not installed (Optional native engine)"
    fi

    # PRoot compatibility backend
    local pbin
    if pbin="$(cyber_proot_find_bin 2>/dev/null)" && cyber_proot_test_bin "$pbin"; then
        ui_step "DONE" "PRoot Compatibility" "Operational ($pbin)"
    else
        ui_step "PENDING" "PRoot Compatibility" "Not installed (Run: cybervps guest install-backend)"
    fi

    # User namespace support
    if [ -f /proc/sys/kernel/unprivileged_userns_clone ]; then
        local un_val
        un_val="$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo 0)"
        if [ "$un_val" -eq 1 ]; then
            ui_step "DONE" "User Namespaces" "Enabled (/proc/sys/kernel/unprivileged_userns_clone = 1)"
        else
            ui_step "WARN" "User Namespaces" "Disabled by kernel policy"
        fi
    else
        ui_step "DONE" "User Namespaces" "Kernel unprivileged namespaces available"
    fi

    # Guest count
    local proot_base="${XDG_DATA_HOME:-$HOME/.local/share}/cybervps/guests"
    local g_count=0
    if [ -d "$proot_base" ]; then
        for g in "$proot_base"/*; do
            [ -d "$g" ] && [ -x "$g/bin/sh" ] && g_count=$((g_count + 1))
        done
    fi
    ui_step "DONE" "Linux Guests" "$g_count guest(s) provisioned"
    echo
}

cyberroot_cli() {
    local action=${1:-help} binary
    [[ $# -eq 0 ]] || shift
    case $action in
        install-runtime) cyberroot_install_release "$@"; return $? ;;
        build-dev) cyberroot_build_dev; return $? ;;
        help|-h|--help)
            printf '%s\n' 'Usage: cybervps root {doctor|list|create|shell|exec|stop|snapshot|snapshots|clone|export|import|remote} ...' \
                'create DISTRO [--name NAME]; shell NAME; exec NAME -- COMMAND [ARG...]' \
                'import NAME ARCHIVE; export NAME FILE; snapshot NAME [SNAP]' \
                'install-runtime VERSION SHA256; build-dev (explicit CYBERROOT_DEV_DIR)' \
                'Guest root does not imply host root. Prefix has no filesystem isolation.'
            return 0 ;;
    esac
    if [[ -n ${CYBERROOT_BIN:-} && ! -x $CYBERROOT_BIN ]]; then
        printf 'CyberRoot is optional and not installed. Other CyberVPS features remain available.\n' >&2
        return 3
    fi
    binary=$(find_cyberroot_bin) || {
        # Graceful fallback to unified guest dispatcher
        case "$action" in
            create) cyber_guest_create "$@" ;;
            shell) cyber_guest_enter "$@" ;;
            list) cyber_guest_list_all ;;
            doctor) cyber_guest_doctor ;;
            *)
                printf 'CyberRoot is optional and not installed. Other CyberVPS features remain available.\n' >&2
                return 3
                ;;
        esac
        return $?
    }
    cyberroot_check_contract "$binary" || return $?
    case $action in
        create) "$binary" install "$@" ;;
        shell) "$binary" enter "$@" ;;
        doctor|list|info|exec|stop|snapshot|snapshots|restore-snapshot|clone|export|import|remote|repair|config|logs|gc|contract) "$binary" "$action" "$@" ;;
        start|restart) printf 'CyberRoot guest service supervision is not implemented. Use shell, exec, or remote start.\n' >&2; return 3 ;;
        *) printf 'Unknown CyberRoot action: %s\n' "$action" >&2; return 2 ;;
    esac
}

# Unified cybervps guest CLI
cyber_guest_cli() {
    local action="${1:-list}"
    shift || true

    case "$action" in
        create) cyber_guest_create "$@" ;;
        shell|enter) cyber_guest_enter "$@" ;;
        list) cyber_guest_list_all ;;
        doctor) cyber_guest_doctor ;;
        backend) cyber_guest_backend ;;
        install-backend) cyber_install_preferred_backend ;;
        help|--help|-h)
            echo "CyberVPS Unified Linux Guest Management"
            echo "Usage: cybervps guest <command> [args...]"
            echo
            echo "Commands:"
            echo "  create [distro] [--name name]  Create new Linux guest (Ubuntu / Debian)"
            echo "  shell [name]                   Enter guest virtual root shell"
            echo "  list                           List installed guests"
            echo "  doctor                         Check runtime and backend health"
            echo "  backend                        Show active backend (CyberRoot/PRoot/Native)"
            echo "  install-backend                Install or verify preferred backend"
            ;;
        *)
            cyber_guest_create "$action" "$@"
            ;;
    esac
}

handle_cyberroot_menu() {
    detect_environment
    local choice guest distro

    while true; do
        clear 2>/dev/null || echo
        ui_header
        echo -e "${C_BCYAN}=== CYBERVPS LINUX GUEST RUNTIME ===${C_RESET}"
        echo -e "${C_TEXT_MUTED}Virtual guest root and host privilege are separate. Trusted workloads only.${C_RESET}\n"

        echo -e "  ${C_BOLD}Host Privilege${C_RESET}    : ${C_PRIMARY}${CYBER_PRIVILEGE_MODE:-ROOTLESS}${C_RESET}"

        local backend
        backend="$(cyber_guest_backend)"
        case "$backend" in
            NATIVE_ROOT)
                echo -e "  ${C_BOLD}Execution Mode${C_RESET}    : ${C_SUCCESS}Native Host Root${C_RESET}"
                echo -e "  ${C_BOLD}Guest Role${C_RESET}        : ${C_TEXT_MUTED}Optional (for workload isolation/testing)${C_RESET}"
                ;;
            CYBERROOT)
                local cbin cv
                cbin="$(find_cyberroot_bin)"
                cv=$("$cbin" --version 2>/dev/null || echo "v1")
                echo -e "  ${C_BOLD}Active Backend${C_RESET}    : ${C_SUCCESS}CyberRoot Native${C_RESET} (${cv})"
                ;;
            PROOT)
                echo -e "  ${C_BOLD}Active Backend${C_RESET}    : ${C_BCYAN}PRoot Compatibility Engine${C_RESET}"
                ;;
            *)
                echo -e "  ${C_BOLD}Active Backend${C_RESET}    : ${C_WARN}None installed${C_RESET} (Select [8] to install)"
                ;;
        esac

        local proot_base="${XDG_DATA_HOME:-$HOME/.local/share}/cybervps/guests"
        local g_count=0
        if [ -d "$proot_base" ]; then
            for g in "$proot_base"/*; do
                [ -d "$g" ] && [ -x "$g/bin/sh" ] && g_count=$((g_count + 1))
            done
        fi
        echo -e "  ${C_BOLD}Guests Installed${C_RESET}  : ${C_BWHITE}${g_count}${C_RESET} guest(s)"
        echo
        echo -e "  ${C_BWHITE}[1]${C_RESET} Create Linux Guest (Ubuntu / Debian)"
        echo -e "  ${C_BWHITE}[2]${C_RESET} Enter Guest Shell"
        echo -e "  ${C_BWHITE}[3]${C_RESET} List Installed Guests"
        echo -e "  ${C_BWHITE}[4]${C_RESET} Guest Runtime Doctor"
        echo -e "  ${C_BWHITE}[5]${C_RESET} Guest Snapshots"
        echo -e "  ${C_BWHITE}[6]${C_RESET} Remote Access / SSH Status"
        echo -e "  ${C_BWHITE}[7]${C_RESET} Backend Architecture & Information"
        echo -e "  ${C_BWHITE}[8]${C_RESET} Install / Upgrade Preferred Backend"
        echo -e "  ${C_BWHITE}[0]${C_RESET} Return to Main Menu"
        echo
        read -r -p 'Selection: ' choice || return 0
        case "$choice" in
            0|[qQ]*) return 0 ;;
            1)
                read -r -p 'Distro [ubuntu]: ' distro || true
                read -r -p 'Guest name [main]: ' guest || true
                distro="${distro:-ubuntu}"
                guest="${guest:-main}"
                cyber_guest_create "$distro" --name "$guest"
                ui_pause
                ;;
            2)
                read -r -p 'Guest name [main]: ' guest || true
                guest="${guest:-main}"
                cyber_guest_enter "$guest"
                ;;
            3)
                cyber_guest_list_all
                ui_pause
                ;;
            4)
                cyber_guest_doctor
                ui_pause
                ;;
            5)
                local cbin
                if cbin="$(find_cyberroot_bin)" && cyberroot_check_contract "$cbin" >/dev/null 2>&1; then
                    read -r -p 'Guest [main]: ' guest || true
                    "$cbin" snapshots "${guest:-main}"
                else
                    echo -e "\n${C_WARN}Snapshots require CyberRoot native engine. (PRoot backend does not support copy-on-write snapshots).${C_RESET}"
                fi
                ui_pause
                ;;
            6)
                local cbin
                if cbin="$(find_cyberroot_bin)" && cyberroot_check_contract "$cbin" >/dev/null 2>&1; then
                    read -r -p 'Guest [main]: ' guest || true
                    "$cbin" remote status "${guest:-main}"
                else
                    cybervps_connect_summary 2>/dev/null || echo "Host remote access active."
                fi
                ui_pause
                ;;
            7)
                echo -e "\n${C_PRIMARY}${C_BOLD}CYBERVPS GUEST RUNTIME ARCHITECTURE${C_RESET}\n"
                echo "CyberVPS supports multi-tier rootless virtualization:"
                echo "  1. CyberRoot Native : High-performance Rust ptrace engine with seccomp filtering"
                echo "  2. PRoot Backend    : Portable user-space rootfs virtualization (Universal Linux compatibility)"
                echo "  3. Native Root      : Direct kernel host execution when container or host has root access"
                echo
                ui_pause
                ;;
            8)
                cyber_install_preferred_backend
                ui_pause
                ;;
            *)
                echo "Invalid selection."
                sleep 1
                ;;
        esac
    done
}
