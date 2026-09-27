#!/usr/bin/env bash
# fresh-install.sh — Fresh user-space rebuild from zero for CyberVPS
# Strictly rootless. Works after near-total $HOME loss.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$SCRIPT_DIR/lib/detect.sh"
# shellcheck source=lib/install.sh
source "$SCRIPT_DIR/lib/install.sh"
# shellcheck source=lib/ports.sh
source "$SCRIPT_DIR/lib/ports.sh"
# shellcheck source=lib/services.sh
source "$SCRIPT_DIR/lib/services.sh"
# shellcheck source=lib/verify.sh
source "$SCRIPT_DIR/lib/verify.sh"

DRY_RUN=0

show_usage() {
    cat << EOF
CyberVPS Fresh Rebuild CLI
Usage: $(basename "$0") [options]

Options:
  --dry-run    Simulate installation without making system changes
  -h, --help   Show this help message
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
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

acquire_lock "fresh-install" || exit 1
trap 'release_lock' EXIT

log_header "CYBERVPS ROOTLESS FRESH REBUILD"
detect_environment
print_system_summary

if [ "$DRY_RUN" -eq 1 ]; then
    log_header "DRY-RUN FRESH INSTALL PLAN"
    log_info "1. Would create standard directories in $CYBER_HOME (bin, apps, config, services, logs, etc.)"
    log_info "2. Would install architecture-compatible Micromamba for $CYBER_ARCH"
    log_info "3. Would create '$CYBERVPS_ENV_NAME' environment with Python 3.12, Node.js 22, and core tools"
    log_info "4. Would install Cloudflared tunnel binary in ~/bin"
    log_info "5. Would allocate collision-free unprivileged ports in ~/.config/cybervps/ports.env"
    log_info "6. Would install CyberVPS CLI helpers (cybervps-*) in ~/bin"
    log_info "7. Would configure login-triggered recovery in ~/.bashrc"
    log_info "8. Would run system health verification"
    exit 0
fi

# 1. Ensure user-space directory tree
log_header "Creating User-Space Directory Layout"
for dir in bin apps config services logs projects examples shared run backups downloads tmp; do
    ensure_directory "$CYBER_HOME/$dir" 0755
done
log_ok "Directory structure established"

# 2. Install Micromamba
install_micromamba || log_warn "Micromamba installation failed or skipped"

# 3. Create hosting environment
setup_hosting_env || log_warn "Hosting environment creation failed or skipped"

# 4. Install Cloudflared
install_cloudflared || log_warn "Cloudflared installation skipped"

# 5. Dynamic Port Allocations (Phase 8)
log_header "Configuring Default Service Ports"
WEB_P="$(reserve_or_select_port "WEB_PORT" 8080)"
PROXY_P="$(reserve_or_select_port "WEB_PROXY_PORT" 8081)"
REDIS_P="$(reserve_or_select_port "REDIS_PORT" 6380)"
log_ok "Allocated WEB_PORT=$WEB_P, WEB_PROXY_PORT=$PROXY_P, REDIS_PORT=$REDIS_P"

# 6. Service CLI Helpers & Login Recovery (Phase 9 & 10)
install_service_cli_helpers
setup_login_recovery

# 7. Verification
log_header "Running Post-Rebuild Verification"
run_cybervps_verification 0

log_header "FRESH REBUILD COMPLETED"
log_ok "CyberVPS user-space hosting toolkit is ready."
exit 0
