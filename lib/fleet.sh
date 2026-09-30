#!/usr/bin/env bash
# lib/fleet.sh — CyberFleet Controller and Node Agent Management
[ -n "${_CYBERVPS_FLEET_SH_LOADED:-}" ] && return 0
_CYBERVPS_FLEET_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/ui.sh
source "$LIB_DIR/ui.sh"
# shellcheck source=lib/sessions.sh
source "$LIB_DIR/sessions.sh"

cybervps_fleet_cli() {
    PYTHONPATH="$CYBERVPS_DIR" python3 -m fleet.cli fleet "$@"
}

cybervps_fleet_start_controller() {
    local port="${1:-8000}"
    local host="${2:-0.0.0.0}"
    ui_info "Starting CyberFleet Controller on $host:$port..."
    session_init_dirs
    session_new "cyberfleet-controller" "PYTHONPATH=\"$CYBERVPS_DIR\" python3 -m fleet.cli fleet controller --host $host --port $port"
    ui_success "CyberFleet Controller started in session 'cyberfleet-controller'."
    ui_kv "Dashboard URL" "http://localhost:$port"
}

cybervps_fleet_stop_controller() {
    ui_info "Stopping CyberFleet Controller..."
    session_stop "cyberfleet-controller"
    ui_success "CyberFleet Controller stopped."
}

cybervps_fleet_start_agent() {
    ui_info "Starting CyberFleet Agent daemon..."
    session_init_dirs
    session_new "cyberfleet-agent" "PYTHONPATH=\"$CYBERVPS_DIR\" python3 -m fleet.cli fleet agent"
    ui_success "CyberFleet Agent started in session 'cyberfleet-agent'."
}

cybervps_fleet_stop_agent() {
    ui_info "Stopping CyberFleet Agent daemon..."
    session_stop "cyberfleet-agent"
    ui_success "CyberFleet Agent stopped."
}

handle_fleet_submenu() {
    while true; do
        clear 2>/dev/null || echo
        ui_header
        echo -e "${C_BCYAN}=== CyberFleet Distributed Cluster Management ===${C_RESET}"
        echo
        cybervps_fleet_cli status 2>/dev/null || true
        echo
        echo -e "  ${C_BWHITE}[1]${C_RESET} View Fleet Nodes & Resources"
        echo -e "  ${C_BWHITE}[2]${C_RESET} Start Controller Service"
        echo -e "  ${C_BWHITE}[3]${C_RESET} Stop Controller Service"
        echo -e "  ${C_BWHITE}[4]${C_RESET} Start Agent Daemon (Outbound Heartbeat)"
        echo -e "  ${C_BWHITE}[5]${C_RESET} Stop Agent Daemon"
        echo -e "  ${C_BWHITE}[6]${C_RESET} Join Fleet (Enroll this VPS)"
        echo -e "  ${C_BWHITE}[7]${C_RESET} Leave Fleet"
        echo -e "  ${C_BWHITE}[8]${C_RESET} Run Live Network Benchmark"
        echo -e "  ${C_BWHITE}[9]${C_RESET} Run Fleet Doctor"
        echo -e "  ${C_BWHITE}[10]${C_RESET} View Fleet Audit Logs"
        echo -e "  ${C_BWHITE}[11]${C_RESET} Drain Node (Maintenance Mode)"
        echo -e "  ${C_BWHITE}[12]${C_RESET} Un-drain Node (Restore Active)"
        echo -e "  ${C_BWHITE}[13]${C_RESET} Safely Remove Node"
        echo -e "  ${C_BWHITE}[0]${C_RESET} Return to Main Menu"
        echo
        local choice=""
        read -rp "Fleet Action: " choice || break
        case "$choice" in
            1)
                cybervps_fleet_cli nodes
                ui_pause
                ;;
            2)
                local cport=""
                read -rp "Controller Port (default 8000): " cport
                [ -z "$cport" ] && cport=8000
                cybervps_fleet_start_controller "$cport"
                ui_pause
                ;;
            3)
                cybervps_fleet_stop_controller
                ui_pause
                ;;
            4)
                cybervps_fleet_start_agent
                ui_pause
                ;;
            5)
                cybervps_fleet_stop_agent
                ui_pause
                ;;
            6)
                local curl="" ctok="" cname=""
                read -rp "Controller URL (e.g. http://1.2.3.4:8000): " curl
                read -rp "Enrollment Token: " ctok
                read -rp "Friendly Node Name (optional): " cname
                if [ -n "$curl" ] && [ -n "$ctok" ]; then
                    if [ -n "$cname" ]; then
                        cybervps_fleet_cli join "$curl" "$ctok" --name "$cname"
                    else
                        cybervps_fleet_cli join "$curl" "$ctok"
                    fi
                fi
                ui_pause
                ;;
            7)
                cybervps_fleet_cli leave
                ui_pause
                ;;
            8)
                cybervps_fleet_cli benchmark
                ui_pause
                ;;
            9)
                cybervps_fleet_cli doctor
                ui_pause
                ;;
            10)
                cybervps_fleet_cli logs
                ui_pause
                ;;
            11)
                local ntarget=""
                read -rp "Enter Node ID or Name to Drain: " ntarget
                if [ -n "$ntarget" ]; then
                    cybervps_fleet_cli drain "$ntarget"
                fi
                ui_pause
                ;;
            12)
                local ntarget=""
                read -rp "Enter Node ID or Name to Un-drain: " ntarget
                if [ -n "$ntarget" ]; then
                    cybervps_fleet_cli drain "$ntarget" --undrain
                fi
                ui_pause
                ;;
            13)
                local ntarget="" nforce=""
                read -rp "Enter Node ID or Name to Remove: " ntarget
                read -rp "Force removal? [y/N]: " nforce
                if [ -n "$ntarget" ]; then
                    if [[ "$nforce" =~ ^[yY] ]]; then
                        cybervps_fleet_cli rm "$ntarget" --force
                    else
                        cybervps_fleet_cli rm "$ntarget"
                    fi
                fi
                ui_pause
                ;;
            0|[qQ]*)
                break
                ;;
        esac
    done
}
