#!/usr/bin/env bash
# lib/ui.sh — Modern Cyber Console Terminal UI (Version 3)
# Dependency-free, pure Bash & ANSI implementation.
# Supports responsive width, Unicode rounded frames with ASCII fallback,
# NO_COLOR compliance, capability badges, and error boundary failure cards.

[ -n "${_CYBERVPS_UI_SH_LOADED:-}" ] && return 0
_CYBERVPS_UI_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"

# Detect color capability and respect NO_COLOR (https://no-color.org)
_setup_colors() {
    if [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = "dumb" ] || [ ! -t 1 ]; then
        C_RESET=""
        C_BOLD=""
        C_DIM=""
        C_CYAN=""
        C_BCYAN=""
        C_BLUE=""
        C_BBLUE=""
        C_GREEN=""
        C_BGREEN=""
        C_YELLOW=""
        C_BYELLOW=""
        C_RED=""
        C_BRED=""
        C_WHITE=""
        C_BWHITE=""
    else
        C_RESET="\033[0m"
        C_BOLD="\033[1m"
        C_DIM="\033[2m"
        C_CYAN="\033[36m"
        C_BCYAN="\033[1;36m"
        C_BLUE="\033[34m"
        C_BBLUE="\033[1;34m"
        C_GREEN="\033[32m"
        C_BGREEN="\033[1;32m"
        C_YELLOW="\033[33m"
        C_BYELLOW="\033[1;33m"
        C_RED="\033[31m"
        C_BRED="\033[1;31m"
        C_WHITE="\033[37m"
        C_BWHITE="\033[1;37m"
    fi
}
_setup_colors

# Detect Unicode capability
ui_has_unicode() {
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *UTF-8*|*utf8*|*UTF8*) return 0 ;;
        *) return 1 ;;
    esac
}

# Setup border glyphs
if ui_has_unicode; then
    UI_TL="╭"
    UI_TR="╮"
    UI_BL="╰"
    UI_BR="╯"
    UI_H="─"
    UI_V="│"
    UI_ML="├"
    UI_MR="┤"
    UI_CHECK="✓"
    UI_CROSS="✕"
    UI_WARN="!"
    UI_BULLET="•"
    UI_DASH="–"
else
    UI_TL="+"
    UI_TR="+"
    UI_BL="+"
    UI_BR="+"
    UI_H="-"
    UI_V="|"
    UI_ML="+"
    UI_MR="+"
    UI_CHECK="OK"
    UI_CROSS="XX"
    UI_WARN="!"
    UI_BULLET="*"
    UI_DASH="-"
fi

# Get terminal width clamped to readable bounds (62 to 90 cols)
ui_get_width() {
    local cols
    cols="$(tput cols 2>/dev/null || true)"
    if [ -z "$cols" ] || ! [[ "$cols" =~ ^[0-9]+$ ]]; then
        cols=80
    fi
    [ "$cols" -lt 62 ] && cols=62
    [ "$cols" -gt 88 ] && cols=88
    echo "$cols"
}

# Print horizontal line of length N
_ui_repeat() {
    local char="$1"
    local count="$2"
    local out=""
    for ((i=0; i<count; i++)); do
        out="${out}${char}"
    done
    echo "$out"
}

# UI Message helpers
ui_success() {
    echo -e "${C_BGREEN}[${UI_CHECK}]${C_RESET} ${C_WHITE}$*${C_RESET}"
}

ui_warning() {
    echo -e "${C_BYELLOW}[${UI_WARN}]${C_RESET} ${C_YELLOW}$*${C_RESET}"
}

ui_error() {
    echo -e "${C_BRED}[${UI_CROSS}]${C_RESET} ${C_RED}$*${C_RESET}"
}

ui_info() {
    echo -e "${C_BCYAN}[i]${C_RESET} ${C_WHITE}$*${C_RESET}"
}

ui_kv() {
    local key="$1"
    local val="$2"
    printf "  ${C_DIM}%-18s${C_RESET} ${C_BWHITE}%s${C_RESET}\n" "$key" "$val"
}

# Pause prompt
ui_pause() {
    [ -t 0 ] || return 0
    local prompt="${1:-Press Enter to continue...}"
    echo
    echo -ne "${C_DIM}${prompt}${C_RESET} "
    read -r _ || true
}

# Render capabilities from the canonical detector.
ui_render_capabilities() {
    local root_label="Root unavailable"
    case "$CYBER_PRIVILEGE_MODE" in
        ROOT) root_label="Root available" ;;
        CONTAINER_ROOT) root_label="Root (container namespace)" ;;
        SUDO_AUTHORIZED) root_label="Sudo authorized" ;;
        CYBERROOT_GUEST) root_label="Guest root only" ;;
    esac
    printf '  Capabilities: [%s] [System Pkgs: %s] [systemd: %s]
' "$root_label" "$CYBER_SYSTEM_PACKAGES" "$CYBER_SYSTEMD_SYSTEM"
    printf '  Resources: %s vCPU / %sMB RAM effective; %sMB free in HOME
' "$CYBER_NPROC" "$CYBER_RAM_TOTAL_MB" "$CYBER_DISK_FREE_MB"
    printf '  Provider: %s; volume persistence: UNKNOWN
' "$CYBER_PROVIDER_HINT"
}

# Render Main CyberVPS V3 Header Card
ui_header() {
    detect_environment
    local width
    width="$(ui_get_width)"
    local inner_width=$((width - 2))

    local line_h
    line_h="$(_ui_repeat "$UI_H" "$inner_width")"

    echo -e "${C_BCYAN}${UI_TL}${line_h}${UI_TR}${C_RESET}"

    # Title line
    local title="CYBERVPS ULTRA - CLOUD CONTROL CENTER"
    local t_len=${#title}
    local pad_left=$(( (inner_width - t_len) / 2 ))
    local pad_right=$(( inner_width - t_len - pad_left ))
    local sp_left
    sp_left="$(_ui_repeat " " "$pad_left")"
    local sp_right
    sp_right="$(_ui_repeat " " "$pad_right")"
    echo -e "${C_BCYAN}${UI_V}${C_RESET}${sp_left}${C_BWHITE}${title}${C_RESET}${sp_right}${C_BCYAN}${UI_V}${C_RESET}"

    echo -e "${C_BCYAN}${UI_ML}${line_h}${UI_MR}${C_RESET}"

    # Profile grid lines
    local host_str="Host: ${CYBER_HOSTNAME:-unknown}"
    local user_str="User: ${CYBER_USER:-unknown} (Mode: ${CYBER_PRIVILEGE_MODE})"
    local os_str="OS:   ${CYBER_DISTRO_PRETTY:-Linux}"
    local arch_str="Arch: ${CYBER_ARCH:-x86_64} (${CYBER_LIBC:-glibc} ${CYBER_LIBC_VERSION:-})"
    local home_str="Home: ${CYBER_HOME:-$HOME}"

    printf "${C_BCYAN}${UI_V}${C_RESET}  %-36s %-38s ${C_BCYAN}${UI_V}${C_RESET}\n" "$host_str" "$user_str"
    printf "${C_BCYAN}${UI_V}${C_RESET}  %-36s %-38s ${C_BCYAN}${UI_V}${C_RESET}\n" "$os_str" "$arch_str"
    printf "${C_BCYAN}${UI_V}${C_RESET}  %-75s ${C_BCYAN}${UI_V}${C_RESET}\n" "$home_str"

    echo -e "${C_BCYAN}${UI_BL}${line_h}${UI_BR}${C_RESET}"
    ui_render_capabilities
    echo
}

# Render a categorized menu section card
ui_menu_section() {
    local title="$1"
    shift
    local width
    width="$(ui_get_width)"
    local inner_width=$((width - 2))

    local title_str="─ ${title} "
    local title_len=${#title_str}
    local rem_len=$((inner_width - title_len))
    [ "$rem_len" -lt 2 ] && rem_len=2
    local right_bar
    right_bar="$(_ui_repeat "$UI_H" "$rem_len")"

    echo -e "${C_BBLUE}${UI_TL}${title_str}${right_bar}${UI_TR}${C_RESET}"
    for item in "$@"; do
        printf "${C_BBLUE}${UI_V}${C_RESET}  %-*s ${C_BBLUE}${UI_V}${C_RESET}\n" "$((inner_width - 4))" "$item"
    done
    local bot_bar
    bot_bar="$(_ui_repeat "$UI_H" "$inner_width")"
    echo -e "${C_BBLUE}${UI_BL}${bot_bar}${UI_BR}${C_RESET}"
}

# Action Failure Card Screen (Error Boundary)
ui_failure_card() {
    local action_title="$1"
    local exit_code="$2"
    local reason="$3"
    local script_name="$4"
    local log_path="$5"

    local width
    width="$(ui_get_width)"
    local inner_width=$((width - 2))
    local line_h
    line_h="$(_ui_repeat "$UI_H" "$inner_width")"

    echo
    echo -e "${C_BRED}${UI_TL}${line_h}${UI_TR}${C_RESET}"
    local banner="  ${UI_CROSS} ${action_title} Failed"
    printf "${C_BRED}${UI_V}${C_RESET}${C_BWHITE}%-*s${C_RESET}${C_BRED}${UI_V}${C_RESET}\n" "$inner_width" "$banner"
    echo -e "${C_BRED}${UI_ML}${line_h}${UI_MR}${C_RESET}"

    local f_code="Exit code : ${exit_code}"
    local f_reason="Reason    : ${reason}"
    local f_script="Script    : $(basename "$script_name")"
    local f_log="Log file  : ${log_path}"

    printf "${C_BRED}${UI_V}${C_RESET}  %-*s${C_BRED}${UI_V}${C_RESET}\n" "$((inner_width - 2))" "$f_code"
    printf "${C_BRED}${UI_V}${C_RESET}  %-*s${C_BRED}${UI_V}${C_RESET}\n" "$((inner_width - 2))" "$f_reason"
    printf "${C_BRED}${UI_V}${C_RESET}  %-*s${C_BRED}${UI_V}${C_RESET}\n" "$((inner_width - 2))" "$f_script"
    printf "${C_BRED}${UI_V}${C_RESET}  %-*s${C_BRED}${UI_V}${C_RESET}\n" "$((inner_width - 2))" "$f_log"

    echo -e "${C_BRED}${UI_BL}${line_h}${UI_BR}${C_RESET}"
    echo
    echo -e "${C_DIM}Suggested action:${C_RESET} CyberVPS dispatches internal shell scripts via Bash where safe."
    echo -e "${C_DIM}Press ${C_BWHITE}[Enter]${C_RESET}${C_DIM} to return to Dashboard, ${C_BWHITE}[L]${C_RESET}${C_DIM} to View Log, or ${C_BWHITE}[D]${C_RESET}${C_DIM} for Diagnostics.${C_RESET}"
}

# View log lines sanitized
ui_view_log() {
    local log_file="$1"
    local lines="${2:-25}"

    if [ ! -f "$log_file" ]; then
        ui_warning "Log file not found: $log_file"
        ui_pause
        return 0
    fi

    echo
    echo -e "${C_BCYAN}=== Recent Log Entries (${log_file}) ===${C_RESET}"
    # Sanitize tokens, secrets, passwords before printing
    tail -n "$lines" "$log_file" | sed -E \
        -e 's/(password|token|secret|key|passwd)[=:][^ ]+/\1=**REDACTED**/gI' \
        -e 's/(ghp_|github_pat_)[A-Za-z0-9_]+/ghp_**REDACTED**/g'
    echo -e "${C_BCYAN}===============================================${C_RESET}"
    ui_pause
}

# Helper to render a row in preflight box
_ui_preflight_row() {
    local label="$1"
    local val="$2"
    local inner_width="$3"

    local plain_val
    plain_val=$(printf '%b' "$val" | sed -r 's/\x1b\[[0-9;]*m//g' 2>/dev/null || printf '%b' "$val" | sed -E $'s/\x1B\\[[0-9;]*[mK]//g')
    local plain_line="  ${label}: ${plain_val}"
    local plain_len=${#plain_line}
    local pad=$((inner_width - plain_len - 1))
    [ "$pad" -lt 0 ] && pad=0
    local sp
    sp="$(_ui_repeat " " "$pad")"

    echo -e "${C_BCYAN}${UI_V}${C_RESET}  ${C_DIM}${label}:${C_RESET} ${val}${sp}${C_BCYAN}${UI_V}${C_RESET}"
}

# Render Preflight Check Box for Bootstrap & Fresh Rebuild
ui_preflight_box() {
    local profile="${1:-hosting}"
    detect_environment

    local width
    width="$(ui_get_width)"
    local inner_width=$((width - 2))
    local line_h
    line_h="$(_ui_repeat "$UI_H" "$inner_width")"

    echo -e "${C_BCYAN}${UI_TL}${line_h}${UI_TR}${C_RESET}"
    local title="CYBERVPS • PREFLIGHT ENVIRONMENT CHECK"
    local t_len=${#title}
    local pad_left=$(( (inner_width - t_len) / 2 ))
    local pad_right=$(( inner_width - t_len - pad_left ))
    local sp_left="$(_ui_repeat " " "$pad_left")"
    local sp_right="$(_ui_repeat " " "$pad_right")"
    echo -e "${C_BCYAN}${UI_V}${C_RESET}${sp_left}${C_BWHITE}${title}${C_RESET}${sp_right}${C_BCYAN}${UI_V}${C_RESET}"
    echo -e "${C_BCYAN}${UI_ML}${line_h}${UI_MR}${C_RESET}"

    # Explicit multi-endpoint diagnostics; dry-run never probes the network.
    detect_network
    local net_status="${C_WHITE}${CYBER_NETWORK_STATE}${C_RESET}"
    if [ "${CYBERVPS_READ_ONLY:-0}" = 1 ]; then net_status="SKIP (read-only)"; fi

    # Home writable
    local home_status="${C_BGREEN}PASS (${CYBER_HOME:-$HOME})${C_RESET}"
    if [ ! -w "${CYBER_HOME:-$HOME}" ]; then
        home_status="${C_BRED}FAIL (read-only)${C_RESET}"
    fi

    local env_status="${CYBER_PRIVILEGE_MODE}"
    local root_status="${CYBER_CAN_ADMIN}"
    [ "$CYBER_IS_CYBERROOT_GUEST" = true ] && root_status="guest only (host privilege unavailable)"
    local pkg_status="${CYBER_SYSTEM_PACKAGES} (${CYBER_PACKAGE_MANAGER:-none})"
    local ready_status="profile: ${profile}; mode: ${CYBERVPS_INSTALL_MODE:-auto}"

    local disk_str="${CYBER_DISK_FREE_MB:-unknown}MB available"
    if [ "${CYBER_DISK_FREE_MB:-unknown}" != "unknown" ]; then
        if [ "$CYBER_DISK_FREE_MB" -ge 1024 ]; then
            disk_str="$((CYBER_DISK_FREE_MB / 1024))GB available"
        fi
    fi

    local ram_str="${CYBER_RAM_AVAIL_MB:-unknown}MB available"
    if [ "${CYBER_RAM_AVAIL_MB:-unknown}" != "unknown" ]; then
        if [ "$CYBER_RAM_AVAIL_MB" -ge 1024 ]; then
            ram_str="$((CYBER_RAM_AVAIL_MB / 1024))GB available"
        fi
    fi

    local libc_str="${CYBER_LIBC:-glibc} ${CYBER_LIBC_VERSION:-}"
    local arch_str="${CYBER_ARCH:-x86_64}"

    _ui_preflight_row "Environment           " "$env_status" "$inner_width"
    _ui_preflight_row "HOME writable         " "$home_status" "$inner_width"
    _ui_preflight_row "Internet connectivity " "$net_status" "$inner_width"
    _ui_preflight_row "Effective CPU / RAM   " "${CYBER_NPROC} vCPU / ${CYBER_RAM_TOTAL_MB}MB" "$inner_width"
    _ui_preflight_row "CPU architecture      " "${C_WHITE}${arch_str}${C_RESET}" "$inner_width"
    _ui_preflight_row "C runtime library     " "${C_WHITE}${libc_str}${C_RESET}" "$inner_width"
    _ui_preflight_row "System root (sudo)    " "$root_status" "$inner_width"
    _ui_preflight_row "System package manager" "$pkg_status" "$inner_width"
    _ui_preflight_row "Selected installation " "$ready_status" "$inner_width"
    _ui_preflight_row "Disk space free       " "${C_WHITE}${disk_str}${C_RESET}" "$inner_width"
    _ui_preflight_row "Effective RAM free    " "${C_WHITE}${ram_str}${C_RESET}" "$inner_width"

    echo -e "${C_BCYAN}${UI_BL}${line_h}${UI_BR}${C_RESET}"
}
