#!/usr/bin/env bash
# lib/connect.sh — Remote connection & access control for CyberVPS
# Manages SSH connection profiles, provider-managed SSH detection,
# local sshd listener discovery, RDP tunneling commands, and Web Terminal endpoints.

[ -n "${_CYBERVPS_CONNECT_SH_LOADED:-}" ] && return 0
_CYBERVPS_CONNECT_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=lib/ui.sh
source "$LIB_DIR/ui.sh"

CONNECT_PROFILE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cybervps"
CONNECT_PROFILE_FILE="$CONNECT_PROFILE_DIR/connect.env"

connect_init() {
    ensure_directory "$CONNECT_PROFILE_DIR" 0700
    if [ ! -f "$CONNECT_PROFILE_FILE" ]; then
        touch "$CONNECT_PROFILE_FILE"
        chmod 0600 "$CONNECT_PROFILE_FILE"
    fi
}

connect_get_ssh_target() {
    connect_init
    if [ -n "${CYBERVPS_SSH_TARGET:-}" ]; then
        echo "$CYBERVPS_SSH_TARGET"
        return 0
    fi
    if [ -f "$CONNECT_PROFILE_FILE" ]; then
        local val
        val="$(awk -F= '$1=="PROVIDER_MANAGED_SSH" {print $2; exit}' "$CONNECT_PROFILE_FILE" 2>/dev/null || true)"
        if [ -n "$val" ]; then
            echo "$val"
            return 0
        fi
    fi
    # Daytona environment variable inspection
    if [ -n "${DAYTONA_SSH_TARGET:-}" ]; then
        echo "$DAYTONA_SSH_TARGET"
        return 0
    fi
    return 1
}

connect_set_ssh_target() {
    local target="$1"
    [ -n "$target" ] || return 2
    connect_init
    # Clean string
    target="${target#"ssh "}"
    # Save to profile
    if grep -q '^PROVIDER_MANAGED_SSH=' "$CONNECT_PROFILE_FILE" 2>/dev/null; then
        sed -i "s|^PROVIDER_MANAGED_SSH=.*|PROVIDER_MANAGED_SSH=$target|" "$CONNECT_PROFILE_FILE"
    else
        echo "PROVIDER_MANAGED_SSH=$target" >> "$CONNECT_PROFILE_FILE"
    fi
    chmod 0600 "$CONNECT_PROFILE_FILE"
    log_ok "Provider managed SSH target saved securely."
}

connect_clear_ssh_target() {
    connect_init
    if [ -f "$CONNECT_PROFILE_FILE" ]; then
        sed -i 's/^PROVIDER_MANAGED_SSH=.*//' "$CONNECT_PROFILE_FILE"
        chmod 0600 "$CONNECT_PROFILE_FILE"
    fi
    log_ok "Provider managed SSH target cleared."
}

connect_redact_ssh() {
    local target="$1"
    [ -n "$target" ] || { echo "Not configured"; return 0; }
    # Format: [ssh ]user@host or user@host:port
    local cmd="ssh "
    if [[ "$target" == ssh\ * ]]; then
        target="${target#ssh }"
    fi
    if [[ "$target" == *"@"* ]]; then
        local user_part="${target%%@*}"
        local host_part="${target#*@}"
        echo "${cmd}********@${host_part}"
    else
        echo "${cmd}${target}"
    fi
}

connect_detect_local_sshd() {
    # Check if local sshd is listening on any port
    local port=0
    if command -v ss >/dev/null 2>&1; then
        local line
        line="$(ss -lntp 2>/dev/null | grep -E 'sshd|:22\b' | head -n 1 || true)"
        if [ -n "$line" ]; then
            port="$(echo "$line" | awk '{print $4}' | awk -F: '{print $NF}')"
        fi
    elif command -v netstat >/dev/null 2>&1; then
        local line
        line="$(netstat -lntp 2>/dev/null | grep -E 'sshd|:22\b' | head -n 1 || true)"
        if [ -n "$line" ]; then
            port="$(echo "$line" | awk '{print $4}' | awk -F: '{print $NF}')"
        fi
    fi

    if [ "$port" -gt 0 ] 2>/dev/null; then
        echo "$port"
        return 0
    fi
    return 1
}

cybervps_connect_ssh() {
    local action="${1:-status}"
    shift || true

    case "$action" in
        set)
            local target="${1:-}"
            [ -n "$target" ] || { log_error "Usage: cybervps connect ssh set '<user@host>'"; return 2; }
            connect_set_ssh_target "$target"
            ;;
        clear)
            connect_clear_ssh_target
            ;;
        --show|show)
            local target
            if target="$(connect_get_ssh_target)"; then
                [[ "$target" == ssh\ * ]] || target="ssh $target"
                echo "$target"
            else
                log_warn "No provider managed SSH target configured. Run: cybervps connect ssh set '<target>'"
                return 1
            fi
            ;;
        status|info|*)
            echo -e "\n${C_PRIMARY}${C_BOLD}SSH Connection Information${C_RESET}"
            local managed_target
            if managed_target="$(connect_get_ssh_target)"; then
                echo -e "  Provider SSH : ${C_SUCCESS}● READY${C_RESET} (Managed by ${CYBER_PROVIDER_HINT})"
                echo -e "  SSH Target   : ${C_TEXT}$(connect_redact_ssh "$managed_target")${C_RESET}"
                echo -e "  Command      : Run ${C_PRIMARY}cybervps connect ssh --show${C_RESET} to reveal command."
            else
                if [ "$CYBER_PROVIDER_HINT" = "Daytona" ]; then
                    echo -e "  Provider SSH : ${C_WARN}○ AVAILABLE / TARGET NOT IMPORTED${C_RESET}"
                    echo -e "  Action       : Import target via: ${C_PRIMARY}cybervps connect ssh set '<target>'${C_RESET}"
                else
                    local local_port
                    if local_port="$(connect_detect_local_sshd)"; then
                        echo -e "  SSH Server   : ${C_SUCCESS}● LISTENING${C_RESET} (Port $local_port)"
                        echo -e "  Connect      : ${C_TEXT}ssh ${CYBER_USER}@<host-ip> -p $local_port${C_RESET}"
                    else
                        echo -e "  SSH Server   : ${C_TEXT_MUTED}○ NOT DETECTED${C_RESET}"
                    fi
                fi
            fi
            echo
            ;;
    esac
}

cybervps_connect_rdp() {
    echo -e "\n${C_PRIMARY}${C_BOLD}RDP / Desktop Connection Information${C_RESET}"
    local is_rdp_listening=false
    if command -v ss >/dev/null 2>&1; then
        ss -lnt 2>/dev/null | grep -q ':3389\b' && is_rdp_listening=true
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | grep -q ':3389\b' && is_rdp_listening=true
    fi

    if [ "$is_rdp_listening" = true ]; then
        echo -e "  XRDP Service : ${C_SUCCESS}● LISTENING${C_RESET} (:3389)"
        echo -e "  Direct Public: ${C_WARN}○ Protected (Localhost only: 127.0.0.1:3389)${C_RESET}"
        echo
        local ssh_target
        if ssh_target="$(connect_get_ssh_target)"; then
            [[ "$ssh_target" == ssh\ * ]] && ssh_target="${ssh_target#ssh }"
            echo -e "${C_BWHITE}Windows PowerShell Tunnel & Connect Instructions:${C_RESET}"
            echo -e "  1. Open Windows PowerShell and run:"
            echo -e "     ${C_BCYAN}ssh -N -L 13389:127.0.0.1:3389 ${ssh_target}${C_RESET}"
            echo -e "  2. Open Windows Remote Desktop (mstsc) and connect to:"
            echo -e "     ${C_BCYAN}127.0.0.1:13389${C_RESET}"
        else
            echo -e "${C_TEXT_MUTED}To connect via secure tunnel, configure provider SSH target first:${C_RESET}"
            echo -e "  ${C_PRIMARY}cybervps connect ssh set '<user@ssh-host>'${C_RESET}"
        fi
    else
        echo -e "  XRDP Service : ${C_TEXT_MUTED}○ NOT RUNNING${C_RESET} (Run: cybervps desktop install/start)"
    fi
    echo
}

cybervps_connect_webterm() {
    echo -e "\n${C_PRIMARY}${C_BOLD}Web Terminal Connection Information${C_RESET}"
    local is_term_running=false
    command -v ttyd >/dev/null 2>&1 && pgrep -x ttyd >/dev/null 2>&1 && is_term_running=true

    local port=7681
    if [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/cybervps/ports.env" ]; then
        port="$(awk -F= '$1=="WEB_TERMINAL_PORT" {print $2; exit}' "${XDG_CONFIG_HOME:-$HOME/.config}/cybervps/ports.env" 2>/dev/null || echo 7681)"
    fi

    if [ "$is_term_running" = true ]; then
        echo -e "  Local Bind   : ${C_SUCCESS}● READY${C_RESET} (http://127.0.0.1:${port})"
        # Check cloudflare tunnel status
        local pub_url=""
        if [ -f "${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/tunnels/webterm.url" ]; then
            pub_url="$(cat "${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/tunnels/webterm.url" 2>/dev/null || true)"
        fi
        if [ -n "$pub_url" ]; then
            echo -e "  Public Tunnel: ${C_SUCCESS}● ONLINE${C_RESET} (${pub_url})"
        else
            echo -e "  Public Tunnel: ${C_TEXT_MUTED}○ Not exposed${C_RESET} (Run: cybervps tunnel start ${port})"
        fi
    else
        echo -e "  Web Terminal : ${C_TEXT_MUTED}○ STOPPED${C_RESET} (Run: cybervps webterm start)"
    fi
    echo
}

cybervps_connect_doctor() {
    detect_environment
    echo -e "\n${C_PRIMARY}${C_BOLD}REMOTE ACCESS DOCTOR${C_RESET}\n"

    # 1. SSH Client
    if command -v ssh >/dev/null 2>&1; then
        ui_step "DONE" "SSH Client" "Installed"
    else
        ui_step "WARN" "SSH Client" "Not found"
    fi

    # 2. Provider SSH
    local managed_target
    if managed_target="$(connect_get_ssh_target)"; then
        ui_step "DONE" "Provider SSH" "Configured ($(connect_redact_ssh "$managed_target"))"
    else
        ui_step "PENDING" "Provider SSH" "Target not imported"
    fi

    # 3. Local sshd
    local local_port
    if local_port="$(connect_detect_local_sshd)"; then
        ui_step "DONE" "Local sshd" "Listening (Port $local_port)"
    else
        if [ "$CYBER_PROVIDER_HINT" = "Daytona" ]; then
            ui_step "DONE" "Local sshd" "Managed externally by Daytona"
        else
            ui_step "PENDING" "Local sshd" "No local listener detected"
        fi
    fi

    # 4. Web Terminal
    local is_term_running=false
    command -v ttyd >/dev/null 2>&1 && pgrep -x ttyd >/dev/null 2>&1 && is_term_running=true
    if [ "$is_term_running" = true ]; then
        ui_step "DONE" "Web Terminal" "Active"
        ui_step "DONE" "ttyd Port" "Listening"
    else
        ui_step "PENDING" "Web Terminal" "Stopped"
        ui_step "PENDING" "ttyd Port" "Inactive"
    fi

    # 5. XRDP Desktop
    local is_rdp_listening=false
    if command -v ss >/dev/null 2>&1; then
        ss -lnt 2>/dev/null | grep -q ':3389\b' && is_rdp_listening=true
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | grep -q ':3389\b' && is_rdp_listening=true
    fi
    if [ "$is_rdp_listening" = true ]; then
        ui_step "DONE" "XRDP Desktop" "Listening on 127.0.0.1:3389"
    else
        ui_step "PENDING" "XRDP Desktop" "Not running"
    fi

    # 6. TCP Exposure
    ui_step "PENDING" "Public Raw TCP" "Unavailable (Firewall/Container Isolation)"
    if [ -n "$managed_target" ]; then
        ui_step "DONE" "SSH Port Forward" "Usable with provider target"
    else
        ui_step "PENDING" "SSH Port Forward" "Requires configured SSH target"
    fi
    echo
}

cybervps_connect_summary() {
    detect_environment
    echo -e "\n${C_PRIMARY}${C_BOLD}CYBERVPS REMOTE ACCESS${C_RESET}\n"

    echo -e "${C_BOLD}SSH${C_RESET}"
    echo -e "  Provider      ${CYBER_PROVIDER_HINT}"
    local managed_target
    if managed_target="$(connect_get_ssh_target)"; then
        echo -e "  Status        ${C_SUCCESS}READY${C_RESET}"
        echo -e "  Command       ${C_TEXT}$(connect_redact_ssh "$managed_target")${C_RESET}"
    else
        echo -e "  Status        ${C_WARN}TARGET NOT IMPORTED${C_RESET}"
        echo -e "  Setup         Run: ${C_PRIMARY}cybervps connect ssh set '<target>'${C_RESET}"
    fi
    echo

    echo -e "${C_BOLD}WEB TERMINAL${C_RESET}"
    local is_term_running=false
    command -v ttyd >/dev/null 2>&1 && pgrep -x ttyd >/dev/null 2>&1 && is_term_running=true
    local port=7681
    if [ "$is_term_running" = true ]; then
        echo -e "  Local         ${C_SUCCESS}http://127.0.0.1:${port}${C_RESET}"
        local pub_url=""
        [ -f "${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/tunnels/webterm.url" ] && pub_url="$(cat "${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/tunnels/webterm.url" 2>/dev/null || true)"
        [ -n "$pub_url" ] && echo -e "  Public        ${C_SUCCESS}${pub_url}${C_RESET}" || echo -e "  Public        ${C_TEXT_MUTED}Not exposed${C_RESET}"
    else
        echo -e "  Status        ${C_TEXT_MUTED}Stopped (Run: cybervps webterm start)${C_RESET}"
    fi
    echo

    echo -e "${C_BOLD}RDP / DESKTOP${C_RESET}"
    local is_rdp_listening=false
    if command -v ss >/dev/null 2>&1; then ss -lnt 2>/dev/null | grep -q ':3389\b' && is_rdp_listening=true; fi
    if [ "$is_rdp_listening" = true ]; then
        echo -e "  XRDP          ${C_SUCCESS}Listening :3389${C_RESET}"
        echo -e "  Direct        ${C_TEXT_MUTED}Not exposed (Protected)${C_RESET}"
        if [ -n "$managed_target" ]; then
            [[ "$managed_target" == ssh\ * ]] && managed_target="${managed_target#ssh }"
            echo -e "  Secure Tunnel ${C_SUCCESS}Ready${C_RESET}\n"
            echo -e "  ${C_BWHITE}Windows:${C_RESET}"
            echo -e "    ssh -N -L 13389:127.0.0.1:3389 ${managed_target}"
            echo -e "    mstsc /v:127.0.0.1:13389"
        fi
    else
        echo -e "  Status        ${C_TEXT_MUTED}Not Installed / Not Running${C_RESET}"
    fi
    echo
}

handle_remote_access_menu() {
    while true; do
        clear 2>/dev/null || echo
        ui_header
        echo -e "${C_BCYAN}=== CyberVPS Remote Access & Connection Center ===${C_RESET}\n"
        cybervps_connect_summary
        echo
        echo -e "  ${C_BWHITE}[1]${C_RESET} SSH Connection Information"
        echo -e "  ${C_BWHITE}[2]${C_RESET} Configure Provider Managed SSH Target"
        echo -e "  ${C_BWHITE}[3]${C_RESET} Web Terminal Connection & Status"
        echo -e "  ${C_BWHITE}[4]${C_RESET} RDP / Desktop Connection & Tunnel Instructions"
        echo -e "  ${C_BWHITE}[5]${C_RESET} Connection Health Doctor"
        echo -e "  ${C_BWHITE}[0]${C_RESET} Return to Main Menu"
        echo
        local act=""
        read -rp "Remote Access Action: " act || break
        case "$act" in
            1) cybervps_connect_ssh; ui_pause ;;
            2)
                local tgt=""
                read -rp "Enter provider SSH target (e.g. user@ssh.app.daytona.io): " tgt
                [ -n "$tgt" ] && connect_set_ssh_target "$tgt"
                ui_pause
                ;;
            3) cybervps_connect_webterm; ui_pause ;;
            4) cybervps_connect_rdp; ui_pause ;;
            5) cybervps_connect_doctor; ui_pause ;;
            0|[qQ]*) break ;;
            *) ;;
        esac
    done
}

cybervps_connect_cli() {
    local cmd="${1:-summary}"
    shift || true
    case "$cmd" in
        ssh) cybervps_connect_ssh "$@" ;;
        rdp|desktop) cybervps_connect_rdp ;;
        webterm) cybervps_connect_webterm ;;
        doctor) cybervps_connect_doctor ;;
        info|summary|*) cybervps_connect_summary ;;
    esac
}
