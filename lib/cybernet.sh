#!/usr/bin/env bash
# lib/cybernet.sh — CyberNet Full-Device VPN & Mobile Gateway Manager
[ -n "${_CYBERVPS_CYBERNET_SH_LOADED:-}" ] && return 0
_CYBERVPS_CYBERNET_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/ui.sh
source "$LIB_DIR/ui.sh"

cybervps_net_cli() {
    PYTHONPATH="$CYBERVPS_DIR" python3 -m fleet.cli net "$@"
}

handle_cybernet_submenu() {
    while true; do
        clear 2>/dev/null || echo
        ui_header
        echo -e "${C_BCYAN}=== CyberNet Full-Device VPN & Mobile Gateway Manager ===${C_RESET}"
        echo
        cybervps_net_cli status 2>/dev/null || true
        echo
        echo -e "  ${C_BWHITE}[1]${C_RESET} List Fleet Gateways (Auto-Scored)"
        echo -e "  ${C_BWHITE}[2]${C_RESET} Enable Gateway on Node"
        echo -e "  ${C_BWHITE}[3]${C_RESET} Disable Gateway on Node"
        echo -e "  ${C_BWHITE}[4]${C_RESET} List Enrolled Mobile Devices"
        echo -e "  ${C_BWHITE}[5]${C_RESET} Revoke Mobile Device"
        echo -e "  ${C_BWHITE}[6]${C_RESET} View Active VPN Sessions"
        echo -e "  ${C_BWHITE}[7]${C_RESET} Run CyberNet Diagnostics Doctor"
        echo -e "  ${C_BWHITE}[8]${C_RESET} Benchmark Gateway Latency"
        echo -e "  ${C_BWHITE}[9]${C_RESET} Generate Mobile Pairing Token"
        echo -e "  ${C_BWHITE}[0]${C_RESET} Return to Main Menu"
        echo
        local choice=""
        read -rp "CyberNet Action: " choice || break
        case "$choice" in
            1)
                cybervps_net_cli gateways
                read -rp "Press Enter to continue..." _
                ;;
            2)
                local nid=""
                read -rp "Enter Node ID to enable as gateway: " nid
                [ -n "$nid" ] && cybervps_net_cli gateway enable "$nid"
                read -rp "Press Enter to continue..." _
                ;;
            3)
                local nid=""
                read -rp "Enter Node ID to disable: " nid
                [ -n "$nid" ] && cybervps_net_cli gateway disable "$nid"
                read -rp "Press Enter to continue..." _
                ;;
            4)
                cybervps_net_cli devices
                read -rp "Press Enter to continue..." _
                ;;
            5)
                local did=""
                read -rp "Enter Device ID to revoke: " did
                [ -n "$did" ] && cybervps_net_cli revoke "$did"
                read -rp "Press Enter to continue..." _
                ;;
            6)
                cybervps_net_cli sessions
                read -rp "Press Enter to continue..." _
                ;;
            7)
                cybervps_net_cli doctor
                read -rp "Press Enter to continue..." _
                ;;
            8)
                local gid=""
                read -rp "Enter Gateway Node ID: " gid
                [ -n "$gid" ] && cybervps_net_cli benchmark "$gid"
                read -rp "Press Enter to continue..." _
                ;;
            9)
                cybervps_net_cli enroll-token create
                read -rp "Press Enter to continue..." _
                ;;
            0)
                break
                ;;
            *)
                echo "Invalid option."
                sleep 1
                ;;
        esac
    done
}
