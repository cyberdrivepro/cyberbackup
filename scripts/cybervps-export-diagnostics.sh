#!/usr/bin/env bash
# scripts/cybervps-export-diagnostics.sh — Sanitized Diagnostics Report Exporter for CyberVPS
# Generates a sanitized text report of system capabilities, permissions, and service status.
# Strictly redacts passwords, tokens, API keys, and private credentials.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=lib/services.sh
source "$LIB_DIR/services.sh"
# shellcheck source=lib/ports.sh
source "$LIB_DIR/ports.sh"
# shellcheck source=lib/execution.sh
source "$LIB_DIR/execution.sh"

detect_environment

DATE_STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_FILE="${1:-$HOME/cybervps-diagnostics-${DATE_STAMP}.txt}"

log_header "Exporting CyberVPS Diagnostics"
log_info "Destination: $OUT_FILE"

build_diagnostics_report() {
    echo "============================================================"
    echo "               CYBERVPS DIAGNOSTICS REPORT                  "
    echo "============================================================"
    echo "Generated At: $(date --iso-8601=seconds 2>/dev/null || date)"
    echo "CyberVPS Version: $CYBERVPS_VERSION"
    echo "Backup Format:    $CYBERVPS_BACKUP_FORMAT"
    echo

    echo "--- 1. HOST & USER PROFILE ---"
    echo "Hostname:     $CYBER_HOSTNAME"
    echo "User:         $CYBER_USER (UID: $CYBER_UID, GID: $CYBER_GID)"
    echo "Home:         $CYBER_HOME"
    echo "Architecture: $CYBER_ARCH ($CYBER_RAW_ARCH)"
    echo "Kernel:       $CYBER_KERNEL"
    echo "Distribution: $CYBER_DISTRO_PRETTY (ID: $CYBER_DISTRO_ID, Ver: $CYBER_DISTRO_VERSION)"
    echo "C Library:    $CYBER_LIBC $CYBER_LIBC_VERSION"
    echo

    echo "--- 2. ROOTLESS CAPABILITIES & RESTRICTIONS ---"
    echo "Root Privilege:        NO ROOT (Strictly unprivileged user space)"
    if command -v apt >/dev/null 2>&1 || command -v apt-get >/dev/null 2>&1; then
        echo "Package Manager:       APT detected — privileged modification unavailable (rootless)"
    elif command -v dnf >/dev/null 2>&1; then
        echo "Package Manager:       DNF detected — privileged modification unavailable (rootless)"
    elif command -v pacman >/dev/null 2>&1; then
        echo "Package Manager:       Pacman detected — privileged modification unavailable (rootless)"
    else
        echo "Package Manager:       No system package manager"
    fi

    local noexec_home="Allowed"
    check_filesystem_noexec "$HOME" && noexec_home="RESTRICTED (noexec mount)"
    local noexec_repo="Allowed"
    check_filesystem_noexec "$SCRIPT_DIR/.." && noexec_repo="RESTRICTED (noexec mount)"
    echo "HOME Mount Exec:       $noexec_home"
    echo "Repo Mount Exec:       $noexec_repo"
    echo "Git Available:         $(command -v git >/dev/null 2>&1 && echo "Yes" || echo "No")"
    echo "Downloader Available:  $( (command -v curl >/dev/null 2>&1 && echo "curl") || (command -v wget >/dev/null 2>&1 && echo "wget") || echo "None")"
    echo

    echo "--- 3. SERVICE BACKEND CANDIDATES ---"
    local sysd_ok="No" tmux_ok="No" screen_ok="No"
    if command -v systemctl >/dev/null 2>&1 && systemctl --user list-units >/dev/null 2>&1; then
        sysd_ok="Yes (active)"
    fi
    command -v tmux >/dev/null 2>&1 && tmux_ok="Yes"
    command -v screen >/dev/null 2>&1 && screen_ok="Yes"
    echo "systemd --user: $sysd_ok"
    echo "tmux:           $tmux_ok"
    echo "screen:         $screen_ok"
    echo "nohup:          Yes (standard fallback)"
    echo "Selected Default: $(get_process_backend)"
    echo

    echo "--- 4. PORT ALLOCATIONS & LISTENERS ---"
    if [ -f "$PORTS_CONFIG_FILE" ]; then
        while IFS='=' read -r k v || [ -n "$k" ]; do
            [[ -z "$k" || "$k" =~ ^# ]] && continue
            local state="inactive"
            is_port_free "$v" || state="LISTENING"
            printf "  %-18s = %-6s [%s]\n" "$k" "$v" "$state"
        done < "$PORTS_CONFIG_FILE"
    else
        echo "  (No ports.env allocated)"
    fi
    echo

    echo "--- 5. USER-SPACE TOOLS STATUS ---"
    echo "micromamba:  $(command -v micromamba 2>/dev/null || echo "not in PATH")"
    echo "python3:     $(command -v python3 2>/dev/null || echo "not in PATH") ($(python3 --version 2>&1 || echo ""))"
    echo "node:        $(command -v node 2>/dev/null || echo "not in PATH") ($(node --version 2>&1 || echo ""))"
    echo "pm2:         $(command -v pm2 2>/dev/null || echo "not in PATH")"
    echo "go:          $(command -v go 2>/dev/null || echo "not in PATH")"
    echo "rustc:       $(command -v rustc 2>/dev/null || echo "not in PATH")"
    echo "redis:       $(command -v redis-server 2>/dev/null || echo "not in PATH")"
    echo "nginx:       $(command -v nginx 2>/dev/null || echo "not in PATH")"
    echo "cloudflared: $(command -v cloudflared 2>/dev/null || echo "not in PATH")"
    echo

    echo "--- 6. RECENT OPERATIONAL LOGS (SANITIZED) ---"
    local log_f="${HOME}/.local/state/cybervps/logs/cybervps.log"
    if [ -f "$log_f" ]; then
        tail -n 25 "$log_f" | sed -E \
            -e 's/(password|token|secret|key|passwd)[=:][^ ]+/\1=**REDACTED**/gI' \
            -e 's/(ghp_|github_pat_)[A-Za-z0-9_]+/ghp_**REDACTED**/g'
    else
        echo "  (No logs recorded)"
    fi
    echo
    echo "============================================================"
    echo "                 END OF DIAGNOSTICS REPORT                  "
    echo "============================================================"
}

build_diagnostics_report > "$OUT_FILE"

chmod 0600 "$OUT_FILE"
log_ok "Diagnostics report generated successfully: $OUT_FILE"
echo "$OUT_FILE"
exit 0
