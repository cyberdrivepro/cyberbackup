#!/usr/bin/env bash
# lib/transfer.sh — CyberTransfer Download & Cloud Storage Delivery
[ -n "${_CYBERVPS_TRANSFER_SH_LOADED:-}" ] && return 0
_CYBERVPS_TRANSFER_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/ui.sh
source "$LIB_DIR/ui.sh"

cybervps_transfer_cli() {
    PYTHONPATH="$CYBERVPS_DIR" python3 -m fleet.cli transfer "$@"
}

cybervps_store_cli() {
    PYTHONPATH="$CYBERVPS_DIR" python3 -m fleet.cli store "$@"
}

handle_transfer_submenu() {
    while true; do
        clear 2>/dev/null || echo
        ui_header
        echo -e "${C_BCYAN}=== CyberTransfer High-Speed File Intake & Delivery ===${C_RESET}"
        echo
        cybervps_transfer_cli jobs 2>/dev/null || true
        echo
        echo -e "  ${C_BWHITE}[1]${C_RESET} Add Download Job (URL Intake - BURST/AUTO/SINGLE/MIRROR)"
        echo -e "  ${C_BWHITE}[2]${C_RESET} View Job Status & Details"
        echo -e "  ${C_BWHITE}[3]${C_RESET} View Distributed BURST Chunks"
        echo -e "  ${C_BWHITE}[4]${C_RESET} Get Cybershare Direct Link"
        echo -e "  ${C_BWHITE}[5]${C_RESET} Retry Failed Transfer"
        echo -e "  ${C_BWHITE}[6]${C_RESET} Cancel Active Transfer"
        echo -e "  ${C_BWHITE}[7]${C_RESET} CyberStore Distributed Storage Overview"
        echo -e "  ${C_BWHITE}[8]${C_RESET} CyberStore Safe Garbage Collection (Dry-Run)"
        echo -e "  ${C_BWHITE}[0]${C_RESET} Return to Main Menu"
        echo
        local choice=""
        read -rp "Transfer Action: " choice || break
        case "$choice" in
            1)
                local durl="" dmode="" dnode=""
                read -rp "Enter HTTPS/HTTP Download URL: " durl
                read -rp "Mode (AUTO, BURST, SINGLE, MIRROR) [default: AUTO]: " dmode
                [ -z "$dmode" ] && dmode="AUTO"
                read -rp "Preferred Node (optional): " dnode
                if [ -n "$durl" ]; then
                    if [ -n "$dnode" ]; then
                        cybervps_transfer_cli add "$durl" --mode "$dmode" --node "$dnode"
                    else
                        cybervps_transfer_cli add "$durl" --mode "$dmode"
                    fi
                fi
                ui_pause
                ;;
            2)
                local jid=""
                read -rp "Enter Job ID: " jid
                if [ -n "$jid" ]; then
                    cybervps_transfer_cli status "$jid"
                fi
                ui_pause
                ;;
            3)
                local jid=""
                read -rp "Enter Job ID: " jid
                if [ -n "$jid" ]; then
                    cybervps_transfer_cli chunks "$jid"
                fi
                ui_pause
                ;;
            4)
                local jid=""
                read -rp "Enter Completed Job ID: " jid
                if [ -n "$jid" ]; then
                    cybervps_transfer_cli link "$jid"
                fi
                ui_pause
                ;;
            5)
                local jid=""
                read -rp "Enter Job ID to Retry: " jid
                if [ -n "$jid" ]; then
                    cybervps_transfer_cli retry "$jid"
                fi
                ui_pause
                ;;
            6)
                local jid=""
                read -rp "Enter Job ID to Cancel: " jid
                if [ -n "$jid" ]; then
                    cybervps_transfer_cli cancel "$jid"
                fi
                ui_pause
                ;;
            7)
                cybervps_store_cli summary
                echo
                cybervps_store_cli files
                ui_pause
                ;;
            8)
                cybervps_store_cli gc --dry-run
                ui_pause
                ;;
            0|[qQ]*)
                break
                ;;
        esac
    done
}
