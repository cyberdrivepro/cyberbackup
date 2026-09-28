#!/usr/bin/env bash
# Capability-driven, non-destructive installation and repair entrypoint.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
VERIFY_ONLY=0
ASSUME_YES=0
PROFILE=""
MODE=auto
MODE_GIVEN=0
show_usage() {
    cat <<'EOF'
CyberVPS Install / Repair
Usage: bash fresh-install.sh [options]
  --profile NAME       minimal, hosting, developer, full, desktop,
                       cyberroot, cybervm, agent_only, custom
  --mode MODE          auto, root, rootless, hybrid (default: auto)
  --components LIST    Custom comma-separated component names
  --repair             Reuse installed tools; repair missing components
  --verify             Check the selected profile; make no changes
  --dry-run            Print the plan; make no changes or downloads
  --yes                Required for unattended installation
  --help               Show this help
Exit: 0 success, 2 usage, 3 capability, 7 dependency, 8 operation,
      9 verification, 10 partial installation (optional failures).
EOF
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --profile|--mode|--components)
            [ "$#" -ge 2 ] && [ -n "$2" ] && [[ "$2" != --* ]] || { show_usage >&2; exit 2; }
            case "$1" in
                --profile) PROFILE="${2,,}" ;;
                --mode) MODE="${2,,}"; MODE_GIVEN=1 ;;
                --components) export CYBERVPS_INSTALL_COMPONENTS="$2" ;;
            esac
            shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --verify|--verify-only) VERIFY_ONLY=1; shift ;;
        --repair) shift ;; # Component installation is already idempotent.
        --yes|-y|--unattended) ASSUME_YES=1; shift ;;
        --help|-h) show_usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; show_usage >&2; exit 2 ;;
    esac
done
if [ "$DRY_RUN" -eq 1 ] || [ "$VERIFY_ONLY" -eq 1 ]; then export CYBERVPS_READ_ONLY=1; fi
# shellcheck source=lib/install.sh
source "$SCRIPT_DIR/lib/install.sh"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"

if { [ -t 0 ] || [ -n "${CYBERVPS_INTERACTIVE:-}" ]; } && [ -z "$PROFILE" ]; then
    if [ "$MODE_GIVEN" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && [ "$VERIFY_ONLY" -eq 0 ]; then
        ui_menu_section 'INSTALL / REBUILD' \
            '[1] Automatic / Recommended' '[2] Root / System Install' \
            '[3] Rootless Portable Install' '[4] Hybrid Install' \
            '[5] Repair Existing Install' '[6] Verify Only' '[7] Dry Run' '[0] Back'
        read -r -p 'Select action [1-7, 0]: ' action || exit 0
        case "$action" in
            1|'') MODE=auto ;; 2) MODE=root ;; 3) MODE=rootless ;; 4) MODE=hybrid ;;
            5) MODE=auto ;; 6) VERIFY_ONLY=1; export CYBERVPS_READ_ONLY=1 ;;
            7) DRY_RUN=1; export CYBERVPS_READ_ONLY=1 ;;
            0|[bB]*) log_info 'Returned to dashboard.'; exit 0 ;;
            *) log_error 'Invalid action.'; exit 2 ;;
        esac
    fi
    ui_menu_section 'SELECT INSTALLATION PROFILE' \
        '[1] Minimal' '[2] Hosting [Default]' '[3] Developer' '[4] Full' \
        '[5] Desktop (opt-in)' '[6] CyberRoot' '[7] CyberVM' '[8] Agent Only' \
        '[9] Custom' '[B] Back to Dashboard'
    read -r -p 'Select profile [1-9, B]: ' choice || exit 0
    case "$choice" in
        1) PROFILE=minimal ;; 2|'') PROFILE=hosting ;; 3) PROFILE=developer ;; 4) PROFILE=full ;;
        5) PROFILE=desktop ;; 6) PROFILE=cyberroot ;; 7) PROFILE=cybervm ;; 8) PROFILE=agent_only ;;
        9) PROFILE=custom
           printf 'Components: python,node,sqlite,build,go,rust,pm2,pnpm,nginx,redis,cloudflared,ttyd,micromamba,desktop,cyberroot,cybervm,agent\n'
           read -r -p 'Comma-separated components: ' CYBERVPS_INSTALL_COMPONENTS || exit 0
           export CYBERVPS_INSTALL_COMPONENTS ;;
        [bB]*) log_info 'Returned to dashboard.'; exit 0 ;;
        *) log_error 'Invalid profile.'; exit 2 ;;
    esac
fi
PROFILE="${PROFILE:-hosting}"
install_profile_components "$PROFILE"
install_resolve_mode "$MODE"
printf '\nSelected profile: %s\n' "$PROFILE"
if [ "$DRY_RUN" -eq 1 ]; then
    log_header 'DRY-RUN INSTALL PLAN'
    install_profile_plan
    exit 0
fi
if [ "$VERIFY_ONLY" -eq 1 ]; then
    install_profile_verify
    exit $?
fi
ui_preflight_box "$PROFILE"
install_profile_plan
if [ "$ASSUME_YES" -eq 0 ]; then
    if [ -t 0 ] || [ -n "${CYBERVPS_INTERACTIVE:-}" ]; then
        read -r -p "Proceed with profile '$PROFILE' in '$CYBERVPS_INSTALL_MODE' mode? [y/N]: " confirm || exit 0
        [[ "$confirm" =~ ^[yY]([eE][sS])?$ ]] || { log_info 'Installation cancelled by user.'; exit 0; }
    else
        log_error 'Unattended installation requires --yes. Use --dry-run to inspect the plan.'
        exit 2
    fi
fi
# Existing tools need only state space; missing stacks get a conservative disk guard.
required_mb=64
for component in "${INSTALL_COMPONENTS[@]}"; do
    if ! install_component_ready "$component"; then
        case "$PROFILE" in minimal|agent_only) required_mb=256 ;; hosting|cybervm|cyberroot) required_mb=1024 ;; *) required_mb=3072 ;; esac
        break
    fi
done
if [[ "${CYBER_DISK_FREE_MB:-unknown}" =~ ^[0-9]+$ ]] && [ "$CYBER_DISK_FREE_MB" -lt "$required_mb" ]; then
    log_error "Insufficient writable space: ${CYBER_DISK_FREE_MB} MiB available; estimated ${required_mb} MiB required."
    exit 3
fi
acquire_lock fresh-install || exit 8
trap 'release_lock' EXIT
rc=0
install_profile "$PROFILE" || rc=$?
# Preserve legacy helper paths and login recovery. No services are started here.
if [ "$rc" -eq 0 ] || [ "$rc" -eq 10 ]; then
    # shellcheck source=lib/services.sh
    source "$SCRIPT_DIR/lib/services.sh"
    install_service_cli_helpers || exit 8
    setup_login_recovery || exit 8
    log_info 'Installation finished. Login recovery depends on a login; provider shutdown still stops services.'
fi
exit "$rc"
