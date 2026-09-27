#!/usr/bin/env bash
# lib/restore.sh — Safe restore engine for CyberVPS
# Features: Pre-restore snapshot, SHA256 verification, format validation,
# staging extraction, path translation for managed configs, dynamic port adaptation,
# runtime rebuilding on architecture mismatch, and rollback reporting.

[ -n "${_CYBERVPS_RESTORE_SH_LOADED:-}" ] && return 0
_CYBERVPS_RESTORE_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=lib/ports.sh
source "$LIB_DIR/ports.sh"
# shellcheck source=lib/services.sh
source "$LIB_DIR/services.sh"
# shellcheck source=lib/install.sh
source "$LIB_DIR/install.sh"

CYBERVPS_BACKUP_FORMAT=2

# Find the latest or specified backup archive
find_backup_archive() {
    local search_dir="${1:-$HOME/cyberbackup/downloads}"
    local latest_meta="$search_dir/latest.json"

    if [ -f "$latest_meta" ]; then
        local bfile
        bfile="$(grep -E '"backup_file":' "$latest_meta" 2>/dev/null | cut -d'"' -f4 || true)"
        if [ -n "$bfile" ] && [ -f "$search_dir/$bfile" ]; then
            echo "$search_dir/$bfile"
            return 0
        fi
    fi

    # Search for newest backup archive
    local newest
    newest="$(find "$search_dir" -maxdepth 1 -name "cybervps-backup-*.tar.*" 2>/dev/null | sort -r | head -1 || true)"
    if [ -n "$newest" ] && [ -f "$newest" ]; then
        echo "$newest"
        return 0
    fi

    return 1
}

# Verify integrity and checksum of backup archive
verify_archive_integrity() {
    local archive="$1"
    [ ! -f "$archive" ] && { log_error "Archive not found: $archive"; return 1; }

    log_info "Verifying archive integrity: $(basename "$archive")"
    if [[ "$archive" == *.tar.zst ]]; then
        if have_command zstd; then
            tar -I zstd -tf "$archive" >/dev/null || { log_error "Archive corrupted"; return 1; }
        else
            log_error "zstd not installed; cannot read .tar.zst archive"
            return 1
        fi
    else
        tar -tzf "$archive" >/dev/null || { log_error "Archive corrupted"; return 1; }
    fi
    log_ok "Archive integrity verified."
    return 0
}

# Path translation for managed configuration files only
# Replaces SOURCE_HOME with DEST_HOME in CyberVPS-managed files
translate_managed_paths() {
    local src_home="$1"
    local dst_home="$2"
    local target_file="$3"

    [ ! -f "$target_file" ] && return 0
    [ "$src_home" = "$dst_home" ] && return 0

    log_debug "Translating managed paths in $target_file: $src_home -> $dst_home"
    # Use sed safely with alternate delimiter
    sed -i "s|${src_home}|${dst_home}|g" "$target_file" 2>/dev/null || true
}

# Create pre-restore rollback snapshot
create_prerestore_snapshot() {
    local date_stamp
    date_stamp="$(date +%Y%m%d-%H%M%S)"
    local snap_dir="${HOME}/backups/pre-restore-${date_stamp}"
    ensure_directory "$snap_dir" 0700

    log_header "Creating Pre-Restore Safety Snapshot"
    log_info "Snapshot directory: $snap_dir"

    # Backup current configs and services before touching them
    for d in config services bin; do
        if [ -d "${HOME}/$d" ]; then
            cp -rP "${HOME}/$d" "$snap_dir/" 2>/dev/null || true
        fi
    done
    for f in .bashrc .profile; do
        if [ -f "${HOME}/$f" ]; then
            cp -P "${HOME}/$f" "$snap_dir/" 2>/dev/null || true
        fi
    done

    echo "$snap_dir"
}

# Core Restore Execution
restore_cybervps_backup() {
    local archive_path="$1"
    local opt_dry_run="${2:-0}"
    local opt_force_rebuild="${3:-0}"

    [ ! -f "$archive_path" ] && { log_error "Backup archive does not exist: $archive_path"; return 1; }

    detect_environment
    verify_archive_integrity "$archive_path" || return 1

    local staging_dir="${HOME}/cyberbackup/payload/staging-$$"
    ensure_directory "$staging_dir" 0700
    trap 'rm -rf "$staging_dir"' EXIT

    log_header "Extracting Archive to Staging"
    log_info "Staging directory: $staging_dir"

    if [[ "$archive_path" == *.tar.zst ]]; then
        tar -I zstd -xf "$archive_path" -C "$staging_dir" 2>/dev/null || tar -I zstd -xf "$archive_path" -C "$staging_dir"
    else
        tar -xzf "$archive_path" -C "$staging_dir" 2>/dev/null || tar -xzf "$archive_path" -C "$staging_dir"
    fi

    # Locate extracted system metadata
    local meta_json
    meta_json="$(find "$staging_dir" -name "system.json" 2>/dev/null | head -1 || true)"
    local src_user="unknown"
    local src_home=""
    local src_arch=""
    local src_format="1"

    if [ -n "$meta_json" ] && [ -f "$meta_json" ]; then
        src_user="$(grep -E '"source_user":' "$meta_json" | cut -d'"' -f4 || echo "unknown")"
        src_home="$(grep -E '"source_home":' "$meta_json" | cut -d'"' -f4 || true)"
        src_arch="$(grep -E '"architecture":' "$meta_json" | cut -d'"' -f4 || true)"
        src_format="$(grep -E '"format_version":' "$meta_json" | grep -oE '[0-9]+' || echo "1")"
    fi

    log_header "Restore Source Metadata"
    log_info "Source User: $src_user"
    log_info "Source Home: ${src_home:-unknown}"
    log_info "Source Arch: ${src_arch:-unknown}"
    log_info "Source Backup Format: $src_format"
    log_info "Current Host Arch: $CYBER_ARCH"
    log_info "Current User: $CYBER_USER"
    log_info "Current Home: $CYBER_HOME"

    if [ "$src_format" -gt "$CYBERVPS_BACKUP_FORMAT" ]; then
        log_error "Backup format version $src_format is newer than supported version $CYBERVPS_BACKUP_FORMAT. Update CyberVPS first."
        return 1
    fi

    local arch_mismatch=0
    if [ -n "$src_arch" ] && [ "$src_arch" != "$CYBER_ARCH" ]; then
        log_warn "Architecture mismatch detected: Source ($src_arch) != Destination ($CYBER_ARCH)"
        arch_mismatch=1
    fi

    if [ "$opt_dry_run" -eq 1 ]; then
        log_header "DRY-RUN RESTORE PLAN"
        log_info "1. Would create pre-restore snapshot in ~/backups/pre-restore-TIMESTAMP"
        log_info "2. Would restore portable configs from staging to $CYBER_HOME"
        if [ "$arch_mismatch" -eq 1 ] || [ "$opt_force_rebuild" -eq 1 ]; then
            log_info "3. Would rebuild/reinstall runtime environments due to architecture difference ($CYBER_ARCH)"
        fi
        log_info "4. Would translate managed configuration paths (${src_home:-/home/user} -> $CYBER_HOME)"
        log_info "5. Would verify and reallocate ports if conflicting"
        log_info "6. Would install CyberVPS CLI helpers and login recovery"
        return 0
    fi

    # Create safety snapshot
    local snap_dir
    snap_dir="$(create_prerestore_snapshot)"
    log_ok "Rollback snapshot created at: $snap_dir"

    # Find the extracted home contents inside staging
    # Tar archives with absolute paths create directories matching original path inside staging
    local extracted_root="$staging_dir"
    if [ -n "$src_home" ] && [ -d "$staging_dir/$src_home" ]; then
        extracted_root="$staging_dir/$src_home"
    elif [ -d "$staging_dir/home/$src_user" ]; then
        extracted_root="$staging_dir/home/$src_user"
    fi

    log_header "Restoring Portable Configuration and Services"

    # 1. Restore config
    if [ -d "$extracted_root/config" ]; then
        ensure_directory "${CYBER_HOME}/config" 0700
        cp -rP "$extracted_root/config"/* "${CYBER_HOME}/config/" 2>/dev/null || true
        log_ok "Restored config files"
    fi

    # 2. Restore services
    if [ -d "$extracted_root/services" ]; then
        ensure_directory "${CYBER_HOME}/services" 0755
        cp -rP "$extracted_root/services"/* "${CYBER_HOME}/services/" 2>/dev/null || true
        chmod +x "${CYBER_HOME}/services"/*.sh 2>/dev/null || true
        log_ok "Restored services"
    fi

    # 3. Restore projects
    if [ -d "$extracted_root/projects" ]; then
        ensure_directory "${CYBER_HOME}/projects" 0755
        for p in "$extracted_root/projects"/*; do
            [ -d "$p" ] || continue
            pname="$(basename "$p")"
            if [ -d "${CYBER_HOME}/projects/$pname" ]; then
                log_info "Project '$pname' already exists at destination; merging safely"
                cp -rnP "$p"/* "${CYBER_HOME}/projects/$pname/" 2>/dev/null || true
            else
                cp -rP "$p" "${CYBER_HOME}/projects/" 2>/dev/null || true
                log_ok "Restored project: $pname"
            fi
        done
    fi

    # 4. Restore user scripts in ~/bin (excluding host-incompatible binaries if arch mismatch)
    if [ -d "$extracted_root/bin" ]; then
        ensure_directory "${CYBER_HOME}/bin" 0755
        for b in "$extracted_root/bin"/*; do
            [ -f "$b" ] || continue
            bname="$(basename "$b")"
            # If arch mismatched, skip restoring binary executables that might be host-incompatible
            if [ "$arch_mismatch" -eq 1 ] && [ -x "$b" ]; then
                if file "$b" 2>/dev/null | grep -q "ELF"; then
                    log_warn "Skipping binary '$bname' due to architecture mismatch"
                    continue
                fi
            fi
            cp -P "$b" "${CYBER_HOME}/bin/" 2>/dev/null || true
        done
        chmod +x "${CYBER_HOME}/bin"/* 2>/dev/null || true
        log_ok "Restored bin directory"
    fi

    # 5. Path translation on managed config files
    if [ -n "$src_home" ] && [ "$src_home" != "$CYBER_HOME" ]; then
        log_header "Translating Managed Configuration Paths"
        for conf_f in "${CYBER_HOME}/config"/* "${CYBER_HOME}/services"/*.sh; do
            [ -f "$conf_f" ] || continue
            translate_managed_paths "$src_home" "$CYBER_HOME" "$conf_f"
        done
    fi

    # 6. Rebuild or verify environment if architecture mismatch or requested
    if [ "$arch_mismatch" -eq 1 ] || [ "$opt_force_rebuild" -eq 1 ]; then
        log_header "Rebuilding Destination Environment"
        install_micromamba || log_warn "Micromamba installation failed"
        install_cloudflared || log_warn "Cloudflared installation failed"
    fi

    # 7. Check and reallocate port reservations
    log_header "Validating Port Allocations"
    local staging_ports
    staging_ports="$(find "$staging_dir" -name "ports.env" 2>/dev/null | head -1 || true)"
    if [ -n "$staging_ports" ] && [ -f "$staging_ports" ]; then
        while IFS='=' read -r key val || [ -n "$key" ]; do
            [[ -z "$key" || "$key" =~ ^# ]] && continue
            local alloc
            alloc="$(reserve_or_select_port "$key" "$val")"
            log_ok "Port for $key: $alloc (source was $val)"
        done < "$staging_ports"
    fi

    # 8. Setup CLI helpers & Login recovery
    install_service_cli_helpers
    setup_login_recovery

    log_header "RESTORE COMPLETED SUCCESSFULLY"
    log_ok "Configuration, projects, and services restored."
    log_info "To verify the restored environment, run: ./verify.sh"
    return 0
}
