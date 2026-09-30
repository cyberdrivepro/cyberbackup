#!/usr/bin/env bash
# lib/public.sh — CyberVPS One-Command Public Access Subsystem
# Exposes authenticated web terminal or any local HTTP service to a secure public HTTPS URL
# via Cloudflare Quick Tunnel without opening firewall ports or raw 0.0.0.0 listeners.

[ -n "${_CYBERVPS_PUBLIC_SH_LOADED:-}" ] && return 0
_CYBERVPS_PUBLIC_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=lib/ui.sh
source "$LIB_DIR/ui.sh"
# shellcheck source=lib/ports.sh
source "$LIB_DIR/ports.sh"
# shellcheck source=lib/webterm.sh
source "$LIB_DIR/webterm.sh"
# shellcheck source=lib/tunnel.sh
source "$LIB_DIR/tunnel.sh"

cybervps_public_start_webterm() {
    echo -e "\n${C_PRIMARY}${C_BOLD}CYBERVPS ONE-COMMAND PUBLIC ACCESS${C_RESET}\n"

    # 1. Ensure ttyd installed
    ui_step "PENDING" "Web Terminal Engine" "Verifying ttyd binary..."
    if ! webterm_ensure_installed; then
        ui_step "FAIL" "Web Terminal Engine" "ttyd could not be installed."
        return 1
    fi
    ui_step "DONE" "Web Terminal Engine" "ttyd binary ready"

    # 2. Ensure authentication credentials
    webterm_ensure_auth
    local auth_file="${XDG_CONFIG_HOME:-$HOME/.config}/cybervps/webterm/auth.env"
    local user="cybervps"
    if [ -f "$auth_file" ]; then
        user="$(awk -F= '$1=="WEBTERM_USER" {gsub(/["'\'']/, "", $2); print $2}' "$auth_file" 2>/dev/null || echo "cybervps")"
    fi
    ui_step "DONE" "Authentication" "Credentials configured (0600 storage)"

    # 3. Start local authenticated web terminal bound strictly to 127.0.0.1
    if ! webterm_is_running; then
        ui_step "PENDING" "Local Service" "Starting authenticated web terminal on 127.0.0.1:7681..."
        if ! webterm_start "main"; then
            ui_step "FAIL" "Local Service" "Failed to start web terminal on 127.0.0.1"
            return 1
        fi
    fi
    ui_step "DONE" "Local Service" "Active on 127.0.0.1:7681 (Protected: localhost only)"

    # 4. Ensure cloudflared installed
    ui_step "PENDING" "Tunnel Engine" "Verifying Cloudflare Tunnel engine..."
    if ! tunnel_ensure_installed; then
        ui_step "FAIL" "Tunnel Engine" "cloudflared could not be installed."
        echo -e "\n${C_WARN}Local terminal remains accessible on: http://127.0.0.1:7681${C_RESET}"
        return 1
    fi
    ui_step "DONE" "Tunnel Engine" "Cloudflare Tunnel engine ready"

    # 5. Start Quick Tunnel
    ui_step "PENDING" "Public Tunnel" "Establishing Cloudflare Quick Tunnel..."
    if ! tunnel_start "webterm" >/dev/null 2>&1; then
        # Check if already running
        if ! tunnel_is_running "webterm"; then
            ui_step "FAIL" "Public Tunnel" "Could not start Cloudflare tunnel. Local terminal remains active."
            return 1
        fi
    fi

    # 6. Retrieve public URL
    local pub_url=""
    local meta_file="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/tunnel/webterm.json"
    local log_file="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/logs/tunnel_webterm.log"
    local i=0
    while [ $i -lt 12 ]; do
        if [ -f "$meta_file" ]; then
            pub_url="$(grep -o '"url": *"[^"]*"' "$meta_file" 2>/dev/null | cut -d'"' -f4 || true)"
            [[ "$pub_url" == https://* ]] && break
        fi
        if [ -f "$log_file" ]; then
            pub_url="$(grep -o 'https://[-a-zA-Z0-9\.]*\.trycloudflare\.com' "$log_file" 2>/dev/null | head -n1 || true)"
            [ -n "$pub_url" ] && break
        fi
        sleep 1
        i=$((i + 1))
    done

    echo
    if [ -n "$pub_url" ] && [ "$pub_url" != "pending" ]; then
        ui_step "DONE" "Public Tunnel" "Online ($pub_url)"
        echo -e "\n${C_SUCCESS}${C_BOLD}CYBERVPS PUBLIC ACCESS${C_RESET}\n"
        echo -e "  Status      : ${C_SUCCESS}● READY${C_RESET}"
        echo -e "  Public URL  : ${C_BCYAN}${pub_url}${C_RESET}"
        echo -e "  Username    : ${C_BWHITE}${user}${C_RESET}"
        echo -e "  Password    : ${C_TEXT_MUTED}hidden (Run: cybervps public auth --show)${C_RESET}"
        echo
        echo -e "${C_BWHITE}Management Commands:${C_RESET}"
        echo -e "  ${C_PRIMARY}cybervps public auth --show${C_RESET}  Reveal login credentials"
        echo -e "  ${C_PRIMARY}cybervps public status${C_RESET}       Check public URL & tunnel health"
        echo -e "  ${C_PRIMARY}cybervps public stop${C_RESET}         Stop public tunnel"
        echo
        return 0
    else
        ui_step "WARN" "Public Tunnel" "Tunnel running but URL acquisition pending."
        echo -e "  Check URL with: ${C_PRIMARY}cybervps public status${C_RESET}"
        echo -e "  Log file: $log_file\n"
        return 0
    fi
}

cybervps_public_start_port() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        log_error "Invalid port number: '$port'. Must be between 1 and 65535."
        return 2
    fi

    echo -e "\n${C_PRIMARY}${C_BOLD}CYBERVPS PUBLIC ACCESS — PORT $port${C_RESET}\n"

    # Ensure cloudflared installed
    tunnel_ensure_installed || return 1

    local target="port-$port"
    if ! tunnel_start "$target"; then
        log_error "Failed to start tunnel for port $port."
        return 1
    fi

    local meta_file="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/tunnel/${target}.json"
    local log_file="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/logs/tunnel_${target}.log"
    local pub_url=""
    local i=0
    while [ $i -lt 10 ]; do
        if [ -f "$meta_file" ]; then
            pub_url="$(grep -o '"url": *"[^"]*"' "$meta_file" 2>/dev/null | cut -d'"' -f4 || true)"
            [[ "$pub_url" == https://* ]] && break
        fi
        if [ -f "$log_file" ]; then
            pub_url="$(grep -o 'https://[-a-zA-Z0-9\.]*\.trycloudflare\.com' "$log_file" 2>/dev/null | head -n1 || true)"
            [ -n "$pub_url" ] && break
        fi
        sleep 1
        i=$((i + 1))
    done

    echo -e "\n${C_SUCCESS}${C_BOLD}PUBLIC SERVICE ACTIVE${C_RESET}\n"
    echo -e "  Status      : ${C_SUCCESS}● ONLINE${C_RESET}"
    echo -e "  Local Bind  : http://127.0.0.1:$port"
    echo -e "  Public URL  : ${C_BCYAN}${pub_url:-Acquiring...}${C_RESET}"
    echo -e "  Stop Command: ${C_PRIMARY}cybervps public stop $port${C_RESET}\n"
    return 0
}

cybervps_public_auth_show() {
    local auth_file="${XDG_CONFIG_HOME:-$HOME/.config}/cybervps/webterm/auth.env"
    if [ ! -f "$auth_file" ]; then
        log_warn "Web terminal authentication credentials not generated yet. Run: cybervps public"
        return 1
    fi

    local user pass
    user="$(awk -F= '$1=="WEBTERM_USER" {gsub(/["'\'']/, "", $2); print $2}' "$auth_file" 2>/dev/null || echo "cybervps")"
    pass="$(awk -F= '$1=="WEBTERM_PASS" {gsub(/["'\'']/, "", $2); print $2}' "$auth_file" 2>/dev/null || true)"

    echo -e "\n${C_PRIMARY}${C_BOLD}CYBERVPS PUBLIC TERMINAL CREDENTIALS${C_RESET}\n"
    echo -e "  Username : ${C_BWHITE}${user}${C_RESET}"
    echo -e "  Password : ${C_BCYAN}${pass}${C_RESET}"
    echo -e "  Storage  : ${C_TEXT_MUTED}${auth_file} (0600)${C_RESET}\n"
}

cybervps_public_status() {
    echo -e "\n${C_PRIMARY}${C_BOLD}CYBERVPS PUBLIC ACCESS STATUS${C_RESET}\n"

    # Web terminal check
    local term_running=false
    webterm_is_running && term_running=true

    # Tunnel check
    local tunnel_running=false
    tunnel_is_running "webterm" && tunnel_running=true

    local meta_file="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/tunnel/webterm.json"
    local pub_url="None"
    if [ -f "$meta_file" ]; then
        pub_url="$(grep -o '"url": *"[^"]*"' "$meta_file" 2>/dev/null | cut -d'"' -f4 || echo "None")"
    fi

    if [ "$term_running" = true ]; then
        echo -e "  Web Terminal : ${C_SUCCESS}● RUNNING${C_RESET} (127.0.0.1:7681)"
    else
        echo -e "  Web Terminal : ${C_TEXT_MUTED}○ STOPPED${C_RESET}"
    fi

    if [ "$tunnel_running" = true ]; then
        echo -e "  Cloudflare   : ${C_SUCCESS}● ONLINE${C_RESET}"
        echo -e "  Public URL   : ${C_BCYAN}${pub_url}${C_RESET}"
    else
        echo -e "  Cloudflare   : ${C_TEXT_MUTED}○ STOPPED${C_RESET}"
        echo -e "  Public URL   : ${C_TEXT_MUTED}Not exposed${C_RESET}"
    fi
    echo
}

cybervps_public_stop() {
    local target="${1:-webterm}"
    [[ "$target" =~ ^[0-9]+$ ]] && target="port-$target"

    echo -e "\n${C_PRIMARY}Stopping public access for '${target}'...${C_RESET}"
    tunnel_stop "$target" || true
    if [ "$target" = "webterm" ]; then
        webterm_stop || true
    fi
    log_ok "Public access stopped."
}

# CLI entrypoint for cybervps public
cybervps_public_cli() {
    local arg="${1:-}"
    shift || true

    case "$arg" in
        auth)
            if [ "${1:-}" = "--show" ] || [ "${1:-}" = "show" ]; then
                cybervps_public_auth_show
            else
                echo "Usage: cybervps public auth --show"
            fi
            ;;
        status)
            cybervps_public_status
            ;;
        stop)
            cybervps_public_stop "$@"
            ;;
        help|--help|-h)
            echo "CyberVPS One-Command Public Access"
            echo "Usage: cybervps public [port] [options]"
            echo
            echo "Commands:"
            echo "  cybervps public              Start authenticated web terminal & Cloudflare Quick Tunnel"
            echo "  cybervps public <port>       Expose any local service (e.g. 8080) via Quick Tunnel"
            echo "  cybervps public auth --show  Reveal login username and password"
            echo "  cybervps public status       View public URL and tunnel status"
            echo "  cybervps public stop [port]  Stop tunnel and public access"
            ;;
        *)
            if [[ "$arg" =~ ^[0-9]+$ ]]; then
                cybervps_public_start_port "$arg"
            elif [ -z "$arg" ]; then
                cybervps_public_start_webterm
            else
                log_error "Unknown public argument: '$arg'. Try: cybervps public help"
                return 2
            fi
            ;;
    esac
}
