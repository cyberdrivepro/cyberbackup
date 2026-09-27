#!/usr/bin/env bash
# fresh-install.sh — Fresh user-space rebuild from zero for CyberVPS
# Strictly rootless. Works after near-total $HOME loss.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$SCRIPT_DIR/lib/detect.sh"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/execution.sh
source "$SCRIPT_DIR/lib/execution.sh"
# shellcheck source=lib/lock.sh
source "$SCRIPT_DIR/lib/lock.sh"
# shellcheck source=lib/install.sh
source "$SCRIPT_DIR/lib/install.sh"
# shellcheck source=lib/ports.sh
source "$SCRIPT_DIR/lib/ports.sh"
# shellcheck source=lib/services.sh
source "$SCRIPT_DIR/lib/services.sh"
# shellcheck source=lib/verify.sh
source "$SCRIPT_DIR/lib/verify.sh"

DRY_RUN=0
ASSUME_YES=0
PROFILE=""

show_usage() {
    cat << EOF
CyberVPS Fresh Rebuild CLI
Usage: $(basename "$0") [options]

Options:
  --profile <name>        Installation profile: minimal, hosting, developer, full
  -y, --yes, --unattended Skip interactive confirmation prompt
  --dry-run               Simulate installation without making system changes
  -h, --help              Show this help message
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --profile)
            PROFILE="${2:-}"
            shift 2
            ;;
        -y|--yes|--unattended)
            ASSUME_YES=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Interactive Profile Selection if not passed via CLI
if [ -z "$PROFILE" ]; then
    if [ -t 0 ] || [ -n "${CYBERVPS_INTERACTIVE:-}" ]; then
        echo
        ui_menu_section "SELECT INSTALLATION PROFILE" \
            "[1] Minimal    (Core user-space layout, portable tools, recovery)" \
            "[2] Hosting    (Python 3.12, Node.js 22, web & proxy tooling) [Default]" \
            "[3] Developer  (Hosting stack + Go, Rust, build toolchains)" \
            "[4] Full       (All supported stacks, runtimes & services)" \
            "[B] Back to Dashboard"
        echo
        choice=""
        if ! read -rp "Select profile [1-4, B]: " choice; then
            choice="2"
        fi
        case "$choice" in
            1) PROFILE="minimal" ;;
            2|"") PROFILE="hosting" ;;
            3) PROFILE="developer" ;;
            4) PROFILE="full" ;;
            [bB]*)
                log_info "Returned to dashboard."
                exit 0
                ;;
            *)
                log_warn "Invalid selection '$choice', defaulting to hosting."
                PROFILE="hosting"
                ;;
        esac
    else
        PROFILE="hosting"
    fi
fi

# Preflight Environment Inspection Box
echo
ui_preflight_box "$PROFILE"
echo

# Interactive confirmation prompt
if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    if [ -t 0 ] || [ -n "${CYBERVPS_INTERACTIVE:-}" ]; then
        confirm=""
        if read -rp "Proceed with installation under profile '${PROFILE}'? [Y/n]: " confirm; then
            if [[ "$confirm" =~ ^[nN] ]]; then
                log_info "Installation cancelled by user."
                exit 0
            fi
        fi
        echo
    fi
fi

acquire_lock "fresh-install" || exit 1
trap 'release_lock' EXIT

if [ "$DRY_RUN" -eq 1 ]; then
    log_header "DRY-RUN FRESH INSTALL PLAN (${PROFILE})"
    log_info "1. Would create standard directories in $CYBER_HOME (bin, apps, config, services, logs, etc.)"
    log_info "2. Would install architecture-compatible Micromamba for $CYBER_ARCH"
    log_info "3. Would deploy selected profile components: $PROFILE"
    log_info "4. Would allocate collision-free unprivileged ports in ~/.config/cybervps/ports.env"
    log_info "5. Would install CyberVPS CLI helpers (cybervps-*) in ~/bin"
    log_info "6. Would configure login-triggered recovery in ~/.bashrc"
    log_info "7. Would run system health verification"
    exit 0
fi

# 1. Ensure user-space directory tree
log_header "Creating User-Space Directory Layout"
for dir in bin apps config services logs projects examples shared run backups downloads tmp; do
    ensure_directory "$CYBER_HOME/$dir" 0755
done
log_ok "Directory structure established"

# 2. Deploy selected profile components
install_profile "$PROFILE"

# 3. Dynamic Port Allocations
log_header "Configuring Default Service Ports"
WEB_P="$(reserve_or_select_port "WEB_PORT" 8080)"
PROXY_P="$(reserve_or_select_port "WEB_PROXY_PORT" 8081)"
REDIS_P="$(reserve_or_select_port "REDIS_PORT" 6380)"
log_ok "Allocated WEB_PORT=$WEB_P, WEB_PROXY_PORT=$PROXY_P, REDIS_PORT=$REDIS_P"

# 4. Service CLI Helpers & Login Recovery
install_service_cli_helpers
setup_login_recovery

# 5. Verification
log_header "Running Post-Rebuild Verification"
run_cybervps_verification 0

log_header "FRESH REBUILD COMPLETED"
log_ok "CyberVPS user-space hosting toolkit is ready (${PROFILE} profile)."
exit 0
