#!/usr/bin/env bash
# lib/migration.sh — Cross-host VPS migration engine for CyberVPS
# Compares source vs destination identities, rewrites managed paths, reallocates conflicting ports,
# and triggers native rebuilds when architecture or OS differences exist.

[ -n "${_CYBERVPS_MIGRATION_SH_LOADED:-}" ] && return 0
_CYBERVPS_MIGRATION_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=lib/restore.sh
source "$LIB_DIR/restore.sh"

execute_vps_migration() {
    local archive_path="$1"
    local opt_dry_run="${2:-0}"

    [ ! -f "$archive_path" ] && { log_error "Archive not found: $archive_path"; return 1; }

    log_header "CYBERVPS CROSS-HOST MIGRATION"
    detect_environment

    log_info "Analyzing backup archive: $(basename "$archive_path")"
    verify_archive_integrity "$archive_path" || return 1

    # Call restore with force_rebuild enabled for cross-host migration
    restore_cybervps_backup "$archive_path" "$opt_dry_run" 1
}
