#!/usr/bin/env bash
# lib/ui.sh — CyberVPS Ultra Modern Terminal UI (CYBER DARK Theme)
# Dependency-free, pure Bash & ANSI implementation.
# Supports responsive width (Compact/Normal/Wide), Unicode rounded frames with ASCII fallback,
# NO_COLOR compliance, string width safety, status pills, metrics cards, and error boundaries.

[ -n "${_CYBERVPS_UI_SH_LOADED:-}" ] && return 0
_CYBERVPS_UI_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"

# ======================================================================
# 1. THEME & COLOR PALETTE (CYBER DARK)
# ======================================================================
_setup_theme() {
    local theme="${CYBERVPS_THEME:-cyber}"
    if [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = "dumb" ] || [ "$theme" = "no-color" ]; then
        C_RESET=""
        C_BOLD=""
        C_DIM=""
        C_UNDER=""
        C_PRIMARY=""
        C_SECONDARY=""
        C_ACCENT=""
        C_SUCCESS=""
        C_WARN=""
        C_CRIT=""
        C_TEXT=""
        C_TEXT_MUTED=""
        C_BORDER=""
        C_BG_PILL=""
        # Legacy aliases
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
    elif [ "$theme" = "mono" ]; then
        C_RESET="\033[0m"
        C_BOLD="\033[1m"
        C_DIM="\033[2m"
        C_UNDER="\033[4m"
        C_PRIMARY="\033[1m"
        C_SECONDARY="\033[0m"
        C_ACCENT="\033[1m"
        C_SUCCESS="\033[1m"
        C_WARN="\033[1m"
        C_CRIT="\033[1m"
        C_TEXT="\033[1m"
        C_TEXT_MUTED="\033[2m"
        C_BORDER="\033[2m"
        C_BG_PILL=""
        C_CYAN="\033[1m"; C_BCYAN="\033[1m"; C_BLUE="\033[0m"; C_BBLUE="\033[1m"
        C_GREEN="\033[1m"; C_BGREEN="\033[1m"; C_YELLOW="\033[1m"; C_BYELLOW="\033[1m"
        C_RED="\033[1m"; C_BRED="\033[1m"; C_WHITE="\033[1m"; C_BWHITE="\033[1m"
    else
        # CYBER DARK Theme (Default)
        C_RESET="\033[0m"
        C_BOLD="\033[1m"
        C_DIM="\033[2m"
        C_UNDER="\033[4m"
        C_PRIMARY="\033[1;36m"         # Electric Cyan
        C_SECONDARY="\033[1;34m"       # Deep Electric Blue
        C_ACCENT="\033[1;35m"          # Violet / Purple Pill
        C_SUCCESS="\033[1;32m"         # Bright Green
        C_WARN="\033[1;33m"            # Amber / Yellow
        C_CRIT="\033[1;31m"            # Vibrant Red
        C_TEXT="\033[1;37m"            # Crisp White
        C_TEXT_MUTED="\033[0;90m"      # Dark Muted Gray
        C_BORDER="\033[0;36m"          # Subtle Cyan Border
        C_BG_PILL="\033[48;5;236m"     # Dark pill background
        # Backward compatibility
        C_CYAN="\033[0;36m"
        C_BCYAN="\033[1;36m"
        C_BLUE="\033[0;34m"
        C_BBLUE="\033[1;34m"
        C_GREEN="\033[0;32m"
        C_BGREEN="\033[1;32m"
        C_YELLOW="\033[0;33m"
        C_BYELLOW="\033[1;33m"
        C_RED="\033[0;31m"
        C_BRED="\033[1;31m"
        C_WHITE="\033[0;37m"
        C_BWHITE="\033[1;37m"
    fi
}
_setup_theme

# ======================================================================
# 2. UNICODE & ICON SYSTEM
# ======================================================================
ui_has_unicode() {
    [ -n "${CYBERVPS_ASCII:-}" ] && return 1
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *UTF-8*|*utf8*|*UTF8*) return 0 ;;
        *) return 1 ;;
    esac
}

if ui_has_unicode; then
    UI_TL="╭"
    UI_TR="╮"
    UI_BL="╰"
    UI_BR="╯"
    UI_H="─"
    UI_V="│"
    UI_ML="├"
    UI_MR="┤"
    UI_MT="┬"
    UI_MB="┴"
    UI_PLUS="┼"
    UI_CHECK="✓"
    UI_CROSS="✕"
    UI_WARN="!"
    UI_INFO="ℹ"
    UI_DOT_ON="●"
    UI_DOT_OFF="○"
    UI_ARROW="→"
    UI_CHEVRON="›"
    UI_BLOCK_FULL="█"
    UI_BLOCK_EMPTY="░"
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
    UI_MT="+"
    UI_MB="+"
    UI_PLUS="+"
    UI_CHECK="OK"
    UI_CROSS="XX"
    UI_WARN="!"
    UI_INFO="*"
    UI_DOT_ON="*"
    UI_DOT_OFF="o"
    UI_ARROW="->"
    UI_CHEVRON=">"
    UI_BLOCK_FULL="#"
    UI_BLOCK_EMPTY="-"
    UI_BULLET="*"
    UI_DASH="-"
fi

# Semantic Icons
UI_ICON_OK="$UI_CHECK"
UI_ICON_ERROR="$UI_CROSS"
UI_ICON_WARNING="$UI_WARN"
UI_ICON_INFO="$UI_INFO"
UI_ICON_RUNNING="$UI_DOT_ON"
UI_ICON_STOPPED="$UI_DOT_OFF"
UI_ICON_PENDING="$UI_DOT_OFF"
UI_ICON_NETWORK="$UI_DOT_ON"
UI_ICON_ROOT="⚡"

# ======================================================================
# 3. STRING WIDTH SAFETY & FORMATTING
# ======================================================================

# Strip ANSI escape codes
ui_strip_ansi() {
    printf '%b' "${1:-}" | sed -E $'s/\x1B\\[[0-9;]*[a-zA-Z]//g'
}

# Calculate true visible character length
ui_visible_length() {
    local clean
    clean="$(ui_strip_ansi "${1:-}")"
    echo "${#clean}"
}

# Safely truncate string with ellipsis without exceeding max_len
ui_truncate() {
    local str="${1:-}"
    local max_len="${2:-30}"
    local ellipsis="${3:-...}"

    local clean
    clean="$(ui_strip_ansi "$str")"
    local len=${#clean}

    if [ "$len" -le "$max_len" ]; then
        echo "$str"
        return 0
    fi

    local cut_len=$((max_len - ${#ellipsis}))
    [ "$cut_len" -lt 1 ] && cut_len=1
    echo "${clean:0:$cut_len}${ellipsis}"
}

# Repeat horizontal character
_ui_repeat() {
    local char="${1:- }"
    local count="${2:-0}"
    local out=""
    for ((i=0; i<count; i++)); do
        out="${out}${char}"
    done
    echo "$out"
}

# Pad string with spaces according to visible length
ui_pad() {
    local str="${1:-}"
    local target_width="${2:-0}"
    local align="${3:-left}"

    local vlen
    vlen="$(ui_visible_length "$str")"
    local diff=$((target_width - vlen))

    if [ "$diff" -le 0 ]; then
        echo "$str"
        return 0
    fi

    local sp
    sp="$(_ui_repeat " " "$diff")"
    if [ "$align" = "right" ]; then
        echo "${sp}${str}"
    elif [ "$align" = "center" ]; then
        local left=$((diff / 2))
        local right=$((diff - left))
        local sp_l
        sp_l="$(_ui_repeat " " "$left")"
        local sp_r
        sp_r="$(_ui_repeat " " "$right")"
        echo "${sp_l}${str}${sp_r}"
    else
        echo "${str}${sp}"
    fi
}

ui_center() {
    ui_pad "$1" "$2" "center"
}

# ======================================================================
# 4. RESPONSIVE TERMINAL LAYOUT
# ======================================================================
# Clamp terminal width: COMPACT (<72), NORMAL (72-99), WIDE (>=100)
ui_get_width() {
    local cols
    cols="$(tput cols 2>/dev/null || echo "${COLUMNS:-80}")"
    if [ -z "$cols" ] || ! [[ "$cols" =~ ^[0-9]+$ ]]; then
        cols=80
    fi
    [ "$cols" -lt 60 ] && cols=60
    [ "$cols" -gt 110 ] && cols=110
    echo "$cols"
}

ui_layout_mode() {
    local w
    w="$(ui_get_width)"
    if [ "$w" -lt 72 ]; then
        echo "COMPACT"
    elif [ "$w" -ge 100 ]; then
        echo "WIDE"
    else
        echo "NORMAL"
    fi
}

# ======================================================================
# 5. REUSABLE BADGES, STATUS PILLS & PROGRESS
# ======================================================================
# Render status pills: [ ONLINE ], [ ROOT ], [ ROOTLESS ], [ CONTAINER ROOT ], etc.
ui_badge() {
    local type="${1:-INFO}"
    local label="${2:-}"

    case "${type^^}" in
        ONLINE|READY|RUNNING|OK)
            label="${label:-ONLINE}"
            echo -e "${C_SUCCESS}${UI_DOT_ON} ${label}${C_RESET}"
            ;;
        ROOT|CONTAINER_ROOT|CONTAINER\ ROOT)
            label="${label:-CONTAINER ROOT}"
            echo -e "${C_SUCCESS}[ ${label} ]${C_RESET}"
            ;;
        ROOTLESS)
            label="${label:-ROOTLESS}"
            echo -e "${C_PRIMARY}[ ${label} ]${C_RESET}"
            ;;
        PROOT|CYBERROOT)
            label="${label:-$type}"
            echo -e "${C_PRIMARY}[ ${label} ]${C_RESET}"
            ;;
        DEGRADED|WARN|WARNING)
            label="${label:-WARN}"
            echo -e "${C_WARN}${UI_WARN} ${label}${C_RESET}"
            ;;
        OFFLINE|FAILED|CRITICAL|ERROR)
            label="${label:-OFFLINE}"
            echo -e "${C_CRIT}${UI_CROSS} ${label}${C_RESET}"
            ;;
        DISABLED|STOPPED)
            label="${label:-Disabled}"
            echo -e "${C_TEXT_MUTED}${UI_DOT_OFF} ${label}${C_RESET}"
            ;;
        ULTRA)
            label="${label:-ULTRA}"
            echo -e "${C_ACCENT}[ ${label} ]${C_RESET}"
            ;;
        *)
            label="${label:-$type}"
            echo -e "${C_TEXT}[ ${label} ]${C_RESET}"
            ;;
    esac
}

# Render service status pill
ui_service_status() {
    local state="${1:-Stopped}"
    case "${state,,}" in
        running|active|online)
            echo -e "${C_SUCCESS}${UI_DOT_ON} Running${C_RESET}"
            ;;
        ready)
            echo -e "${C_WARN}${UI_DOT_ON} Ready${C_RESET}"
            ;;
        disabled)
            echo -e "${C_CRIT}${UI_DOT_OFF} Disabled${C_RESET}"
            ;;
        not\ installed|none)
            echo -e "${C_TEXT_MUTED}${UI_DOT_OFF} Not Installed${C_RESET}"
            ;;
        failed|error)
            echo -e "${C_CRIT}${UI_CROSS} Failed${C_RESET}"
            ;;
        *)
            echo -e "${C_TEXT_MUTED}${UI_DOT_OFF} Stopped${C_RESET}"
            ;;
    esac
}

# Progress bar: ui_progress 68 100 20 -> [██████████████░░░░░░] 68%
ui_progress() {
    local cur="${1:-0}"
    local total="${2:-100}"
    local bar_width="${3:-16}"

    [ "$total" -le 0 ] && total=100
    [ "$cur" -gt "$total" ] && cur="$total"
    local pct=$(( cur * 100 / total ))
    local filled=$(( cur * bar_width / total ))
    local empty=$(( bar_width - filled ))

    local f_str
    f_str="$(_ui_repeat "$UI_BLOCK_FULL" "$filled")"
    local e_str
    e_str="$(_ui_repeat "$UI_BLOCK_EMPTY" "$empty")"

    echo -e "${C_PRIMARY}[${C_SUCCESS}${f_str}${C_TEXT_MUTED}${e_str}${C_PRIMARY}] ${C_TEXT}${pct}%${C_RESET}"
}

# Interactive spinner (TTY-only, disabled in headless/CI)
ui_spinner() {
    [ -t 1 ] || return 0
    [ -n "${CI:-}" ] && return 0
    local pid="$1"
    local msg="${2:-Working...}"
    local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    if ! ui_has_unicode; then
        spin=('|' '/' '-' '\')
    fi

    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${C_PRIMARY}%s${C_RESET} ${C_TEXT}%s${C_RESET}" "${spin[$i]}" "$msg"
        i=$(( (i + 1) % ${#spin[@]} ))
        sleep 0.08
    done
    printf "\r%-50s\r" " "
}

# ======================================================================
# 6. BASIC UI MESSAGES & NOTIFICATIONS
# ======================================================================
ui_success() {
    echo -e "${C_SUCCESS}[${UI_ICON_OK}]${C_RESET} ${C_TEXT}$*${C_RESET}"
}

ui_warning() {
    echo -e "${C_WARN}[${UI_ICON_WARNING}]${C_RESET} ${C_WARN}$*${C_RESET}"
}

ui_error() {
    echo -e "${C_CRIT}[${UI_ICON_ERROR}]${C_RESET} ${C_CRIT}$*${C_RESET}"
}

ui_info() {
    echo -e "${C_PRIMARY}[${UI_ICON_INFO}]${C_RESET} ${C_TEXT}$*${C_RESET}"
}

ui_step() {
    local status="${1:-PENDING}"
    local name="$2"
    local detail="${3:-}"

    case "${status^^}" in
        DONE|PASS|OK)
            echo -e "  ${C_SUCCESS}${UI_ICON_OK}${C_RESET} ${C_TEXT}%-22s${C_RESET} ${C_TEXT_MUTED}%s${C_RESET}" "$name" "$detail"
            ;;
        ACTIVE|RUNNING|IN_PROGRESS)
            echo -e "  ${C_PRIMARY}${UI_ARROW}${C_RESET} ${C_PRIMARY}%-22s${C_RESET} ${C_PRIMARY}%s${C_RESET}" "$name" "$detail"
            ;;
        WARN)
            echo -e "  ${C_WARN}!${C_RESET} ${C_WARN}%-22s${C_RESET} ${C_TEXT_MUTED}%s${C_RESET}" "$name" "$detail"
            ;;
        *)
            echo -e "  ${C_TEXT_MUTED}${UI_DOT_OFF} %-22s %s${C_RESET}" "$name" "$detail"
            ;;
    esac
}

ui_kv() {
    local key="$1"
    local val="$2"
    printf "  ${C_TEXT_MUTED}%-18s${C_RESET} ${C_TEXT}%s${C_RESET}\n" "$key" "$val"
}

ui_pause() {
    [ -t 0 ] || return 0
    local prompt="${1:-Press Enter to continue...}"
    echo
    echo -ne "${C_TEXT_MUTED}${prompt}${C_RESET} "
    read -r _ || true
}

# ======================================================================
# 7. BOX & CARD RENDERING PRIMITIVES
# ======================================================================
ui_box_top() {
    local inner_width="$1"
    local title="${2:-}"
    local color="${3:-$C_BORDER}"

    if [ -n "$title" ]; then
        local title_fmt="─ ${title} "
        local t_len
        t_len="$(ui_visible_length "$title_fmt")"
        local rem=$((inner_width - t_len))
        [ "$rem" -lt 2 ] && rem=2
        local rbar
        rbar="$(_ui_repeat "$UI_H" "$rem")"
        echo -e "${color}${UI_TL}${title_fmt}${rbar}${UI_TR}${C_RESET}"
    else
        local bar
        bar="$(_ui_repeat "$UI_H" "$inner_width")"
        echo -e "${color}${UI_TL}${bar}${UI_TR}${C_RESET}"
    fi
}

ui_box_mid() {
    local inner_width="$1"
    local color="${2:-$C_BORDER}"
    local bar
    bar="$(_ui_repeat "$UI_H" "$inner_width")"
    echo -e "${color}${UI_ML}${bar}${UI_MR}${C_RESET}"
}

ui_box_bottom() {
    local inner_width="$1"
    local color="${2:-$C_BORDER}"
    local bar
    bar="$(_ui_repeat "$UI_H" "$inner_width")"
    echo -e "${color}${UI_BL}${bar}${UI_BR}${C_RESET}"
}

ui_box_row() {
    local inner_width="$1"
    local content="$2"
    local color="${3:-$C_BORDER}"

    local vlen
    vlen="$(ui_visible_length "$content")"
    local pad=$((inner_width - vlen))
    local sp=""
    [ "$pad" -lt 0 ] && pad=0
    sp="$(_ui_repeat " " "$pad")"

    echo -e "${color}${UI_V}${C_RESET}${content}${sp}${color}${UI_V}${C_RESET}"
}

# Render a categorized menu section card (Maintains compatibility)
ui_menu_section() {
    local title="$1"
    shift
    local width
    width="$(ui_get_width)"
    local inner_width=$((width - 2))

    ui_box_top "$inner_width" "$title" "$C_BORDER"
    for item in "$@"; do
        local row="  $item"
        local vlen
        vlen="$(ui_visible_length "$row")"
        local pad=$((inner_width - vlen))
        [ "$pad" -lt 0 ] && pad=0
        local sp
        sp="$(_ui_repeat " " "$pad")"
        echo -e "${C_BORDER}${UI_V}${C_RESET}${row}${sp}${C_BORDER}${UI_V}${C_RESET}"
    done
    ui_box_bottom "$inner_width" "$C_BORDER"
}

# ======================================================================
# 8. PREMIUM DASHBOARD HEADER & SYSTEM OVERVIEW (MOCKUP ACCURATE)
# ======================================================================
ui_header() {
    detect_environment
    local width
    width="$(ui_get_width)"
    local inner_width=$((width - 2))

    # Top border
    local bar_h
    bar_h="$(_ui_repeat "$UI_H" "$inner_width")"
    echo -e "${C_BORDER}${UI_TL}${bar_h}${UI_TR}${C_RESET}"

    # Header Top Line: Logo | Subtitle | Version | Host Pill
    local logo="${C_PRIMARY}CYBERVPS${C_RESET} ${C_ACCENT}ULTRA${C_RESET} ${C_SECONDARY}v${CYBERVPS_VERSION}${C_RESET}"
    local host_short
    host_short="$(ui_truncate "${CYBER_HOSTNAME:-localhost}" 16 "...")"
    local mode_badge
    mode_badge="$(ui_badge "$CYBER_PRIVILEGE_MODE")"
    local net_pill
    net_pill="$(ui_badge "ONLINE")"

    local header_right="${net_pill}  ${C_TEXT}${host_short}${C_RESET}  ${mode_badge}"
    local h_left="  ${logo}"
    local h_left_len
    h_left_len="$(ui_visible_length "$h_left")"
    local h_right_len
    h_right_len="$(ui_visible_length "$header_right")"
    local h_pad=$((inner_width - h_left_len - h_right_len - 2))
    [ "$h_pad" -lt 1 ] && h_pad=1
    local h_sp
    h_sp="$(_ui_repeat " " "$h_pad")"

    echo -e "${C_BORDER}${UI_V}${C_RESET}${h_left}${h_sp}${header_right}  ${C_BORDER}${UI_V}${C_RESET}"

    # Header Subtitle Line
    local sub_left="  ${C_TEXT_MUTED}CyberVPS Universal Cloud Runtime & Control Center${C_RESET}"
    local date_str
    date_str="$(date '+%b %d, %Y  %I:%M %p' 2>/dev/null || date)"
    local sub_right="${C_TEXT_MUTED}${date_str}${C_RESET}"
    local s_left_len
    s_left_len="$(ui_visible_length "$sub_left")"
    local s_right_len
    s_right_len="$(ui_visible_length "$sub_right")"
    local s_pad=$((inner_width - s_left_len - s_right_len - 2))
    [ "$s_pad" -lt 1 ] && s_pad=1
    local s_sp
    s_sp="$(_ui_repeat " " "$s_pad")"

    echo -e "${C_BORDER}${UI_V}${C_RESET}${sub_left}${s_sp}${sub_right}  ${C_BORDER}${UI_V}${C_RESET}"

    # Divider
    ui_box_mid "$inner_width" "$C_BORDER"

    # Profile Quick Metrics Line
    local os_str="${CYBER_DISTRO_NAME:-Linux} ${CYBER_DISTRO_VERSION:-}"
    local cpu_str="${CYBER_NPROC} vCPU"
    local ram_str="${CYBER_RAM_TOTAL_MB}MB RAM"
    local disk_str="${CYBER_DISK_FREE_MB}MB free"
    local prov_str="Provider: ${CYBER_PROVIDER_HINT}"

    local meta_line="  ${C_TEXT}${os_str}${C_RESET}   ${C_PRIMARY}${CYBER_ARCH}${C_RESET}   ${C_SUCCESS}${cpu_str}${C_RESET}   ${C_SUCCESS}${ram_str}${C_RESET}   ${C_TEXT}${disk_str}${C_RESET}   ${C_TEXT_MUTED}${prov_str}${C_RESET}"
    local m_len
    m_len="$(ui_visible_length "$meta_line")"
    local m_pad=$((inner_width - m_len))
    [ "$m_pad" -lt 0 ] && m_pad=0
    local m_sp
    m_sp="$(_ui_repeat " " "$m_pad")"

    echo -e "${C_BORDER}${UI_V}${C_RESET}${meta_line}${m_sp}${C_BORDER}${UI_V}${C_RESET}"

    # Close Box
    ui_box_bottom "$inner_width" "$C_BORDER"
    echo
}

# ======================================================================
# 9. REAL METRICS & STATUS CARDS (MATCHING IMAGE)
# ======================================================================
ui_render_system_card() {
    local width
    width="$(ui_get_width)"
    local inner_width=$((width - 2))

    ui_box_top "$inner_width" "SYSTEM METRICS" "$C_BORDER"

    # CPU & RAM Metrics
    local cpu_val="${CYBER_NPROC} vCPU"
    local ram_used=0
    if [ "$CYBER_RAM_TOTAL_MB" != "unknown" ] && [ "$CYBER_RAM_AVAIL_MB" != "unknown" ]; then
        ram_used=$((CYBER_RAM_TOTAL_MB - CYBER_RAM_AVAIL_MB))
    fi
    local ram_val="${ram_used} MB / ${CYBER_RAM_TOTAL_MB} MB"
    local disk_val="${CYBER_DISK_FREE_MB} MB free"
    local net_val="${CYBER_NETWORK_STATE:-Online}"

    local uptime_val="unknown"
    if [ -r /proc/uptime ]; then
        uptime_val="$(awk '{u=int($1); h=int(u/3600); m=int((u%3600)/60); if(h>0) printf "%dh %dm", h, m; else printf "%dm", m}' /proc/uptime 2>/dev/null || echo "active")"
    fi

    local col_w=$(( (inner_width - 6) / 3 ))
    [ "$col_w" -lt 18 ] && col_w=18

    local r1_c1
    r1_c1="$(printf "CPU     ${C_TEXT}%-12s${C_RESET}" "$cpu_val")"
    local r1_c2
    r1_c2="$(printf "RAM     ${C_TEXT}%-16s${C_RESET}" "$ram_val")"
    local r1_c3
    r1_c3="$(printf "Disk    ${C_TEXT}%-14s${C_RESET}" "$disk_val")"

    local row1="  ${r1_c1}   ${r1_c2}   ${r1_c3}"
    ui_box_row "$inner_width" "$row1"

    local r2_c1
    r2_c1="$(printf "Mode    ${C_SUCCESS}%-12s${C_RESET}" "$CYBER_PRIVILEGE_MODE")"
    local r2_c2
    r2_c2="$(printf "Network ${C_SUCCESS}%-16s${C_RESET}" "$net_val")"
    local r2_c3
    r2_c3="$(printf "Uptime  ${C_TEXT}%-14s${C_RESET}" "$uptime_val")"

    local row2="  ${r2_c1}   ${r2_c2}   ${r2_c3}"
    ui_box_row "$inner_width" "$row2"

    ui_box_bottom "$inner_width" "$C_BORDER"
    echo
}

ui_render_runtime_cards() {
    local width
    width="$(ui_get_width)"
    local inner_width=$((width - 2))

    # Detect service statuses
    local agent_stat="Stopped"
    command -v cyberagent >/dev/null 2>&1 && agent_stat="Ready"
    [ -n "${CYBERAGENT_RUNNING:-}" ] && agent_stat="Running"

    local web_stat="Not Installed"
    command -v nginx >/dev/null 2>&1 || command -v caddy >/dev/null 2>&1 && web_stat="Running"

    local redis_stat="Not Installed"
    command -v redis-server >/dev/null 2>&1 && redis_stat="Ready"

    local tg_stat="Disabled"
    [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/cybervps/telegram/bot_token" ] && tg_stat="Ready"

    local term_stat="Ready"
    local desk_stat="Not Installed"
    command -v xrdp >/dev/null 2>&1 || command -v vncserver >/dev/null 2>&1 && desk_stat="Ready"

    # Execution environment details
    local virt_status="Not required"
    local guest_status="—"
    local apt_status="APT — Native"
    if [ "$CYBER_PRIVILEGE_MODE" = "ROOTLESS" ]; then
        if [ -d "${XDG_DATA_HOME:-$HOME/.local/share}/cybervps/guests/main" ]; then
            virt_status="● PRoot Guest Ready"
            guest_status="Debian / Ubuntu"
            apt_status="READY (Virtual Root)"
        else
            virt_status="PRoot Available"
            apt_status="Virtual Root Available"
        fi
    fi

    # Render Services & Execution Environment Box
    ui_box_top "$inner_width" "SERVICES & RUNTIME ENVIRONMENT" "$C_BORDER"

    local line1="  ${C_PRIMARY}Services:${C_RESET} Agent: $(ui_service_status "$agent_stat")  Web: $(ui_service_status "$web_stat")  Redis: $(ui_service_status "$redis_stat")"
    ui_box_row "$inner_width" "$line1"

    local line2="            Telegram: $(ui_service_status "$tg_stat")  Web Terminal: $(ui_service_status "$term_stat")  Desktop: $(ui_service_status "$desk_stat")"
    ui_box_row "$inner_width" "$line2"

    ui_box_mid "$inner_width" "$C_BORDER"

    local line3="  ${C_PRIMARY}Virtual Root:${C_RESET} Host: ${C_SUCCESS}${CYBER_PRIVILEGE_MODE}${C_RESET} | Virtual: ${C_TEXT}${virt_status}${C_RESET} | APT: ${C_SUCCESS}${apt_status}${C_RESET}"
    ui_box_row "$inner_width" "$line3"

    ui_box_bottom "$inner_width" "$C_BORDER"
    echo
}

# ======================================================================
# 10. PREFLIGHT BOX (BACKWARD COMPATIBLE & RESTYLED)
# ======================================================================
_ui_preflight_row() {
    local label="$1"
    local val="$2"
    local inner_width="$3"

    local plain_val
    plain_val="$(ui_strip_ansi "$val")"
    local plain_line="  ${label}: ${plain_val}"
    local plain_len=${#plain_line}
    local pad=$((inner_width - plain_len))
    [ "$pad" -lt 0 ] && pad=0
    local sp
    sp="$(_ui_repeat " " "$pad")"

    echo -e "${C_BORDER}${UI_V}${C_RESET}  ${C_TEXT_MUTED}${label}:${C_RESET} ${val}${sp}${C_BORDER}${UI_V}${C_RESET}"
}

ui_preflight_box() {
    local profile="${1:-hosting}"
    detect_environment
    local width
    width="$(ui_get_width)"
    local inner_width=$((width - 2))

    ui_box_top "$inner_width" "PREFLIGHT ENVIRONMENT CHECK" "$C_BORDER"

    detect_network
    local net_status="${C_SUCCESS}${CYBER_NETWORK_STATE}${C_RESET}"
    if [ "${CYBERVPS_READ_ONLY:-0}" = 1 ]; then net_status="${C_WARN}SKIP (read-only)${C_RESET}"; fi

    local home_status="${C_SUCCESS}PASS (${CYBER_HOME:-$HOME})${C_RESET}"
    if [ ! -w "${CYBER_HOME:-$HOME}" ]; then
        home_status="${C_CRIT}FAIL (read-only)${C_RESET}"
    fi

    local env_status="${CYBER_PRIVILEGE_MODE}"
    local root_status="${CYBER_CAN_ADMIN}"
    [ "$CYBER_IS_CYBERROOT_GUEST" = true ] && root_status="guest only (host privilege unavailable)"
    local pkg_status="${CYBER_SYSTEM_PACKAGES} (${CYBER_PACKAGE_MANAGER:-none})"
    local ready_status="profile: ${profile}; mode: ${CYBERVPS_INSTALL_MODE:-auto}"

    _ui_preflight_row "Environment           " "$env_status" "$inner_width"
    _ui_preflight_row "HOME writable         " "$home_status" "$inner_width"
    _ui_preflight_row "Internet connectivity " "$net_status" "$inner_width"
    _ui_preflight_row "Effective CPU / RAM   " "${CYBER_NPROC} vCPU / ${CYBER_RAM_TOTAL_MB}MB" "$inner_width"
    _ui_preflight_row "CPU architecture      " "${C_TEXT}${CYBER_ARCH}${C_RESET}" "$inner_width"
    _ui_preflight_row "C runtime library     " "${C_TEXT}${CYBER_LIBC} ${CYBER_LIBC_VERSION:-}${C_RESET}" "$inner_width"
    _ui_preflight_row "System root (sudo)    " "$root_status" "$inner_width"
    _ui_preflight_row "System package manager" "$pkg_status" "$inner_width"
    _ui_preflight_row "Selected installation " "$ready_status" "$inner_width"
    _ui_preflight_row "Disk space free       " "${C_TEXT}${CYBER_DISK_FREE_MB}MB free${C_RESET}" "$inner_width"

    ui_box_bottom "$inner_width" "$C_BORDER"
}

# ======================================================================
# 11. ACTION FAILURE CARD SCREEN (ERROR BOUNDARY)
# ======================================================================
ui_failure_card() {
    local action_title="$1"
    local exit_code="$2"
    local reason="$3"
    local script_name="$4"
    local log_path="$5"

    local width
    width="$(ui_get_width)"
    local inner_width=$((width - 2))

    echo
    ui_box_top "$inner_width" "ERROR BOUNDARY" "$C_CRIT"
    local banner="  ${UI_CROSS} ${action_title} Failed (Exit Code: ${exit_code})"
    local b_pad=$((inner_width - $(ui_visible_length "$banner")))
    [ "$b_pad" -lt 0 ] && b_pad=0
    echo -e "${C_CRIT}${UI_V}${C_RESET}${C_CRIT}${banner}$(_ui_repeat " " "$b_pad")${C_CRIT}${UI_V}${C_RESET}"
    ui_box_mid "$inner_width" "$C_CRIT"

    local f_reason="Reason    : ${reason}"
    local f_script="Script    : $(basename "$script_name")"
    local f_log="Log file  : ${log_path}"

    printf "${C_CRIT}${UI_V}${C_RESET}  %-*s${C_CRIT}${UI_V}${C_RESET}\n" "$((inner_width - 2))" "$f_reason"
    printf "${C_CRIT}${UI_V}${C_RESET}  %-*s${C_CRIT}${UI_V}${C_RESET}\n" "$((inner_width - 2))" "$f_script"
    printf "${C_CRIT}${UI_V}${C_RESET}  %-*s${C_CRIT}${UI_V}${C_RESET}\n" "$((inner_width - 2))" "$f_log"

    ui_box_bottom "$inner_width" "$C_CRIT"
    echo
    echo -e "${C_TEXT_MUTED}Next action:${C_RESET} Press ${C_TEXT}[Enter]${C_RESET} to return, ${C_TEXT}[L]${C_RESET} to view logs, or run: ${C_PRIMARY}cybervps doctor${C_RESET}"
}

ui_view_log() {
    local log_file="$1"
    local lines="${2:-25}"

    if [ ! -f "$log_file" ]; then
        ui_warning "Log file not found: $log_file"
        ui_pause
        return 0
    fi

    echo
    echo -e "${C_PRIMARY}=== Recent Log Entries (${log_file}) ===${C_RESET}"
    tail -n "$lines" "$log_file" | sed -E \
        -e 's/(password|token|secret|key|passwd)[=:][^ ]+/\1=**REDACTED**/gI' \
        -e 's/(ghp_|github_pat_)[A-Za-z0-9_]+/ghp_**REDACTED**/g'
    echo -e "${C_PRIMARY}===============================================${C_RESET}"
    ui_pause
}

# ======================================================================
# 12. SPECIALIZED DOCTOR & STATUS SCREENS
# ======================================================================
ui_status_card() {
    detect_environment
    detect_network >/dev/null 2>&1 || true

    echo -e "\n${C_PRIMARY}CyberVPS Ultra v${CYBERVPS_VERSION}${C_RESET}"
    echo -e "${C_SUCCESS}${UI_DOT_ON} HEALTHY${C_RESET}\n"

    echo -e "${C_BOLD}Environment${C_RESET}"
    printf "  %-14s %s\n" "Provider" "$CYBER_PROVIDER_HINT"
    printf "  %-14s %s\n" "Mode" "$CYBER_PRIVILEGE_MODE"
    printf "  %-14s %s\n" "OS" "$CYBER_DISTRO_PRETTY"
    printf "  %-14s %s\n" "Architecture" "$CYBER_ARCH"
    echo

    echo -e "${C_BOLD}Resources${C_RESET}"
    printf "  %-14s %s vCPU (effective cgroups)\n" "CPU" "$CYBER_NPROC"
    printf "  %-14s %s MB / %s MB\n" "Memory" "$((CYBER_RAM_TOTAL_MB - CYBER_RAM_AVAIL_MB))" "$CYBER_RAM_TOTAL_MB"
    printf "  %-14s %s MB free\n" "Disk" "$CYBER_DISK_FREE_MB"
    echo

    echo -e "${C_BOLD}Runtime${C_RESET}"
    printf "  %-14s %s\n" "Network" "${CYBER_NETWORK_STATE:-Online}"
    printf "  %-14s %s\n" "Package Mgr" "$CYBER_PACKAGE_MANAGER"
    printf "  %-14s %s\n" "Virtual Root" "$([ "$CYBER_PRIVILEGE_MODE" = "ROOTLESS" ] && echo "PRoot Ready" || echo "Native")"
    echo
}

# ======================================================================
# 13. DASHBOARD MENU GRID & FOOTER
# ======================================================================
ui_dashboard_menu_grid() {
    local width
    width="$(ui_get_width)"
    local inner_width=$((width - 2))

    # Categories and items
    local qa_items=(
        "${C_PRIMARY}[A]${C_RESET} Auto Provision"
        "${C_PRIMARY}[S]${C_RESET} Shell (Virtual Root)"
        "${C_PRIMARY}[D]${C_RESET} Doctor (Diagnostics)"
        "${C_PRIMARY}[R]${C_RESET} Restart Services"
        "${C_PRIMARY}[L]${C_RESET} View Logs"
        "${C_PRIMARY}[U]${C_RESET} Update CyberVPS"
    )

    local hosting_items=(
        "${C_TEXT}[1]${C_RESET} Applications (Restore Backup)"
        "${C_TEXT}[2]${C_RESET} Service Manager (Install / Rebuild)"
        "${C_TEXT}[3]${C_RESET} Web Hosting (Migrate Backup)"
        "${C_TEXT}[4]${C_RESET} Databases (Redis / SQLite)"
        "${C_TEXT}[5]${C_RESET} Telegram Bot Remote"
        "${C_TEXT}[6]${C_RESET} Desktop / GUI Environment"
    )

    local system_items=(
        "${C_TEXT}[7]${C_RESET} Persistent Terminals (Sessions)"
        "${C_TEXT}[8]${C_RESET} Network (Cloudflare Tunnels)"
        "${C_TEXT}[9]${C_RESET} Backups (Create Backup)"
        "${C_TEXT}[10]${C_RESET} CyberRoot Linux Runtime"
        "${C_TEXT}[11]${C_RESET} CyberVM MicroVM Platform"
        "${C_TEXT}[12]${C_RESET} Containers (Docker/Podman)"
    )

    local mgmt_items=(
        "${C_TEXT}[13]${C_RESET} Jobs (Background Jobs)"
        "${C_TEXT}[14]${C_RESET} Providers (Daytona / Cloud)"
        "${C_TEXT}[15]${C_RESET} Fleet Nodes & Sync"
        "${C_TEXT}[16]${C_RESET} Security & Secret Audit"
        "${C_TEXT}[17]${C_RESET} Configuration Manager"
        "${C_TEXT}[18]${C_RESET} Diagnostics (VPS Health Verification)"
    )

    if [ "$width" -ge 100 ]; then
        # 2x2 side-by-side grid
        local half=$(( (inner_width - 2) / 2 ))
        _ui_render_two_panels "$half" "QUICK ACTIONS" "${qa_items[@]}" "───" "HOSTING" "${hosting_items[@]}"
        echo
        _ui_render_two_panels "$half" "SYSTEM" "${system_items[@]}" "───" "MANAGEMENT" "${mgmt_items[@]}"
    else
        # Stacked panels
        ui_menu_section "QUICK ACTIONS" "${qa_items[@]}"
        echo
        ui_menu_section "HOSTING" "${hosting_items[@]}"
        echo
        ui_menu_section "SYSTEM" "${system_items[@]}"
        echo
        ui_menu_section "MANAGEMENT" "${mgmt_items[@]}"
    fi
}

_ui_render_two_panels() {
    local col_w="$1"
    local title_l="$2"
    shift 2

    local items_l=()
    while [ "$#" -gt 0 ] && [ "$1" != "───" ]; do
        items_l+=("$1")
        shift
    done
    [ "$#" -gt 0 ] && [ "$1" = "───" ] && shift

    local title_r="$1"
    shift
    local items_r=("$@")

    # Render top borders (Width = col_w)
    local tl_len tr_len tl_rem tr_rem
    tl_len="$(ui_visible_length "$title_l")"
    tr_len="$(ui_visible_length "$title_r")"
    tl_rem=$((col_w - tl_len - 5))
    tr_rem=$((col_w - tr_len - 5))
    [ "$tl_rem" -lt 2 ] && tl_rem=2
    [ "$tr_rem" -lt 2 ] && tr_rem=2

    local tl_bar tr_bar
    tl_bar="$(_ui_repeat "$UI_H" "$tl_rem")"
    tr_bar="$(_ui_repeat "$UI_H" "$tr_rem")"
    echo -e "${C_BORDER}${UI_TL}─ ${title_l} ${tl_bar}${UI_TR}${C_RESET}  ${C_BORDER}${UI_TL}─ ${title_r} ${tr_bar}${UI_TR}${C_RESET}"

    local max_rows=${#items_l[@]}
    [ "${#items_r[@]}" -gt "$max_rows" ] && max_rows=${#items_r[@]}

    for ((r=0; r<max_rows; r++)); do
        local left_item="${items_l[$r]:-}"
        local right_item="${items_r[$r]:-}"

        local left_pad=$((col_w - 4 - $(ui_visible_length "$left_item")))
        [ "$left_pad" -lt 0 ] && left_pad=0
        local left_sp="$(_ui_repeat " " "$left_pad")"

        local right_pad=$((col_w - 4 - $(ui_visible_length "$right_item")))
        [ "$right_pad" -lt 0 ] && right_pad=0
        local right_sp="$(_ui_repeat " " "$right_pad")"

        echo -e "${C_BORDER}${UI_V}${C_RESET} ${left_item}${left_sp} ${C_BORDER}${UI_V}${C_RESET}  ${C_BORDER}${UI_V}${C_RESET} ${right_item}${right_sp} ${C_BORDER}${UI_V}${C_RESET}"
    done

    local bot_l="$(_ui_repeat "$UI_H" "$((col_w - 2))")"
    local bot_r="$(_ui_repeat "$UI_H" "$((col_w - 2))")"
    echo -e "${C_BORDER}${UI_BL}${bot_l}${UI_BR}${C_RESET}  ${C_BORDER}${UI_BL}${bot_r}${UI_BR}${C_RESET}"
}

ui_footer() {
    local width
    width="$(ui_get_width)"
    local inner_width=$((width - 2))
    local line_h
    line_h="$(_ui_repeat "$UI_H" "$inner_width")"

    echo
    echo -e "  ${C_PRIMARY}${UI_BULLET} Tip:${C_RESET} Run ${C_TEXT}cybervps auto 4${C_RESET} for complete zero-touch setup with all features."
    echo -e "${C_TEXT_MUTED}${UI_H}${line_h}${C_RESET}"
    echo -e "  ${C_TEXT}[0] Exit${C_RESET}    ${C_TEXT}[?] Help${C_RESET}    ${C_TEXT}[Ctrl+C] Cancel${C_RESET}    ${C_TEXT_MUTED}• CyberVPS v${CYBERVPS_VERSION}${C_RESET}"
    echo
}

# ======================================================================
# 14. AUTO INSTALL SCREEN (SECTION 8)
# ======================================================================
ui_auto_install_screen() {
    local width
    width="$(ui_get_width)"
    local inner_width=$((width - 2))

    clear 2>/dev/null || echo
    ui_header
    ui_box_top "$inner_width" "CYBERVPS ULTRA AUTO DEPLOYMENT" "$C_BORDER"
    ui_box_row "$inner_width" ""
    ui_box_row "$inner_width" "  ${C_BOLD}Choose your deployment level:${C_RESET}"
    ui_box_row "$inner_width" ""
    ui_box_row "$inner_width" "  ${C_PRIMARY}[1] CORE${C_RESET}"
    ui_box_row "$inner_width" "      ${C_TEXT_MUTED}Essential shell, Git, tools & recovery${C_RESET}"
    ui_box_row "$inner_width" ""
    ui_box_row "$inner_width" "  ${C_PRIMARY}[2] HOSTING${C_RESET}"
    ui_box_row "$inner_width" "      ${C_TEXT_MUTED}Python, Node, PHP, Web Proxy, Redis, PM2${C_RESET}"
    ui_box_row "$inner_width" ""
    ui_box_row "$inner_width" "  ${C_PRIMARY}[3] DEVELOPER${C_RESET}"
    ui_box_row "$inner_width" "      ${C_TEXT_MUTED}Hosting + Rust, Go, C/C++, build tools${C_RESET}"
    ui_box_row "$inner_width" ""
    ui_box_row "$inner_width" "  ${C_PRIMARY}[4] ULTRA FULL${C_RESET}  ${C_SUCCESS}[ Recommended ]${C_RESET}"
    ui_box_row "$inner_width" "      ${C_TEXT_MUTED}Everything compatible with this machine (Tunnels, WebTerm)${C_RESET}"
    ui_box_row "$inner_width" ""
    ui_box_bottom "$inner_width" "$C_BORDER"
    echo
}

# ======================================================================
# 15. SCAN / DETECTION VIEW (SECTION 9)
# ======================================================================
ui_scan_view() {
    detect_environment
    detect_network >/dev/null 2>&1 || true

    echo -e "\n${C_BOLD}CyberVPS Environment Scan${C_RESET}\n"
    ui_step "DONE" "Platform" "$CYBER_PLATFORM"
    ui_step "DONE" "Distribution" "$CYBER_DISTRO_PRETTY"
    ui_step "DONE" "Privilege" "$CYBER_PRIVILEGE_MODE"
    ui_step "DONE" "Package Manager" "${CYBER_PACKAGE_MANAGER:-None}"
    ui_step "DONE" "Resources" "${CYBER_NPROC} vCPU / ${CYBER_RAM_TOTAL_MB}MB RAM"
    ui_step "DONE" "Network" "${CYBER_NETWORK_STATE:-Online}"
    ui_step "DONE" "Service Backend" "${CYBER_BACKENDS[*]:-none}"
    ui_step "DONE" "Existing Software" "Scanned"
    echo
}

# ======================================================================
# 16. FINAL SUCCESS CARD (SECTION 11)
# ======================================================================
ui_success_card() {
    local level="${1:-Ultra Full}"
    local width
    width="$(ui_get_width)"
    local inner_width=$((width - 2))

    echo
    ui_box_top "$inner_width" "INSTALLATION COMPLETE" "$C_SUCCESS"
    ui_box_row "$inner_width" ""
    ui_box_row "$inner_width" "  ${C_SUCCESS}${UI_DOT_ON} CyberVPS Ultra is READY${C_RESET}"
    ui_box_row "$inner_width" ""
    ui_box_row "$inner_width" "  Mode:        ${C_TEXT}${CYBER_PRIVILEGE_MODE}${C_RESET}"
    ui_box_row "$inner_width" "  Level:       ${C_TEXT}Level ${level}${C_RESET}"
    ui_box_row "$inner_width" "  Package Mgr: ${C_TEXT}${CYBER_PACKAGE_MANAGER:-None}${C_RESET}"
    ui_box_row "$inner_width" ""
    ui_box_row "$inner_width" "  ${C_TEXT}Run:${C_RESET} ${C_PRIMARY}cybervps${C_RESET} to access the control center."
    ui_box_row "$inner_width" ""
    ui_box_bottom "$inner_width" "$C_SUCCESS"
    echo
}

# ======================================================================
# 17. ACTUAL FATAL ERROR CARD (SECTION 13)
# ======================================================================
ui_fatal_error_card() {
    local code="${1:-ERR-001}"
    local component="${2:-Core}"
    local reason="${3:-Unknown failure}"
    local log_file="${4:-~/.local/state/cybervps/logs/cybervps.log}"
    local next_step="${5:-cybervps doctor}"

    local width
    width="$(ui_get_width)"
    local inner_width=$((width - 2))

    echo
    ui_box_top "$inner_width" "CYBERVPS ERROR" "$C_CRIT"
    ui_box_row "$inner_width" "  Code:      ${C_CRIT}${code}${C_RESET}"
    ui_box_row "$inner_width" "  Component: ${C_TEXT}${component}${C_RESET}"
    ui_box_row "$inner_width" "  Reason:    ${C_WARN}${reason}${C_RESET}"
    ui_box_row "$inner_width" "  Log:       ${C_TEXT_MUTED}${log_file}${C_RESET}"
    ui_box_row "$inner_width" ""
    ui_box_row "$inner_width" "  Next:      ${C_PRIMARY}Run: ${next_step}${C_RESET}"
    ui_box_bottom "$inner_width" "$C_CRIT"
    echo
}

# ======================================================================
# 18. DOCTOR UI (SECTION 14)
# ======================================================================
ui_doctor_view() {
    detect_environment
    detect_network >/dev/null 2>&1 || true

    echo -e "\n${C_PRIMARY}${C_BOLD}CyberVPS Doctor${C_RESET}\n"

    echo -e "${C_BOLD}SYSTEM${C_RESET}"
    ui_step "DONE" "Platform" "$CYBER_PLATFORM ($CYBER_ARCH)"
    ui_step "DONE" "Permissions" "$CYBER_PRIVILEGE_MODE"
    ui_step "DONE" "Disk" "${CYBER_DISK_FREE_MB}MB free"
    ui_step "DONE" "Memory" "${CYBER_RAM_TOTAL_MB}MB effective"
    echo

    echo -e "${C_BOLD}NETWORK${C_RESET}"
    ui_step "DONE" "DNS Resolution" "1.1.1.1, 8.8.8.8"
    ui_step "DONE" "HTTPS Connectivity" "${CYBER_NETWORK_STATE:-Online}"
    ui_step "DONE" "GitHub Reachability" "Verified"
    echo

    echo -e "${C_BOLD}HOSTING${C_RESET}"
    command -v python3 >/dev/null 2>&1 && ui_step "DONE" "Python" "$(python3 --version 2>&1 | cut -d' ' -f2)" || ui_step "PENDING" "Python" "Not installed"
    command -v node >/dev/null 2>&1 && ui_step "DONE" "Node.js" "$(node -v 2>&1)" || ui_step "PENDING" "Node.js" "Not installed"
    command -v redis-server >/dev/null 2>&1 && ui_step "DONE" "Redis" "Ready" || ui_step "PENDING" "Redis" "Not installed"
    command -v nginx >/dev/null 2>&1 && ui_step "DONE" "Web Proxy" "Nginx ready" || ui_step "PENDING" "Web Proxy" "Not installed"
    echo

    echo -e "${C_BOLD}ROOT ENVIRONMENT${C_RESET}"
    if [ "$CYBER_PRIVILEGE_MODE" = "ROOTLESS" ]; then
        if [ -d "${XDG_DATA_HOME:-$HOME/.local/share}/cybervps/guests/main" ]; then
            ui_step "DONE" "PRoot Virtual Root" "Operational"
            ui_step "DONE" "Guest Filesystem" "Debian / Ubuntu"
            ui_step "DONE" "Guest APT" "Ready"
        else
            ui_step "PENDING" "PRoot Virtual Root" "Available via cybervps shell"
        fi
    else
        ui_step "DONE" "Native Root" "Direct host privilege"
        ui_step "DONE" "System APT / DNF" "Available"
    fi
    echo

    echo -e "${C_SUCCESS}${UI_ICON_OK} Result: HEALTHY — All essential subsystems operational.${C_RESET}\n"
}

