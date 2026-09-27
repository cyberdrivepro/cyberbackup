#!/usr/bin/env bash
# lib/remote.sh — Remote storage abstraction and backup synchronization for CyberVPS
# Supports rclone remotes, local/mounted paths, and HTTPS download sources.
# Features: Atomic uploads, verification, and safe retention management.

[ -n "${_CYBERVPS_REMOTE_SH_LOADED:-}" ] && return 0
_CYBERVPS_REMOTE_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"

REMOTE_CONFIG_FILE="${CYBERVPS_ROOT}/remote.conf"

load_remote_config() {
    local cfg="${1:-$REMOTE_CONFIG_FILE}"
    if [ -f "$cfg" ]; then
        parse_env_file "$cfg"
    fi
    CYBERVPS_REMOTE="${CYBERVPS_REMOTE:-}"
    CYBERVPS_KEEP_LOCAL="${CYBERVPS_KEEP_LOCAL:-0}"
    CYBERVPS_KEEP_REMOTE="${CYBERVPS_KEEP_REMOTE:-0}"
}

# Upload a backup snapshot to configured remote
upload_snapshot() {
    local archive_path="$1"
    load_remote_config

    if [ -z "$CYBERVPS_REMOTE" ]; then
        log_error "No remote storage configured. Please edit remote.conf (see remote.example.conf)."
        return 1
    fi

    [ ! -f "$archive_path" ] && { log_error "Archive file not found: $archive_path"; return 1; }

    local backup_dir
    backup_dir="$(dirname "$archive_path")"
    local archive_name
    archive_name="$(basename "$archive_path")"

    log_header "Uploading Backup to Remote"
    log_info "Target Remote: $CYBERVPS_REMOTE"
    log_info "Archive: $archive_name"

    # 1. Rclone remote
    if [[ "$CYBERVPS_REMOTE" == *:* ]] && ! [[ "$CYBERVPS_REMOTE" == /* ]]; then
        if ! have_command rclone; then
            log_error "rclone command not found in PATH"
            return 1
        fi

        log_info "Uploading archive via rclone..."
        rclone copy "$archive_path" "$CYBERVPS_REMOTE" || { log_error "Failed to upload archive"; return 1; }

        if [ -f "$backup_dir/latest.json" ]; then
            rclone copy "$backup_dir/latest.json" "$CYBERVPS_REMOTE" || true
        fi
        if [ -f "$backup_dir/SHA256SUMS" ]; then
            rclone copy "$backup_dir/SHA256SUMS" "$CYBERVPS_REMOTE" || true
        fi

        # Verify remote object exists
        if rclone ls "$CYBERVPS_REMOTE/$archive_name" >/dev/null 2>&1; then
            log_ok "Upload verified: $CYBERVPS_REMOTE/$archive_name"
        else
            log_error "Upload verification failed; object not listed on remote"
            return 1
        fi

    # 2. Local or mounted filesystem path
    elif [ -d "$CYBERVPS_REMOTE" ] || [[ "$CYBERVPS_REMOTE" == /* ]]; then
        ensure_directory "$CYBERVPS_REMOTE"
        log_info "Copying to mounted/local directory..."
        cp "$archive_path" "$CYBERVPS_REMOTE/" || return 1
        [ -f "$backup_dir/latest.json" ] && cp "$backup_dir/latest.json" "$CYBERVPS_REMOTE/" || true
        [ -f "$backup_dir/SHA256SUMS" ] && cp "$backup_dir/SHA256SUMS" "$CYBERVPS_REMOTE/" || true
        log_ok "Copied successfully to $CYBERVPS_REMOTE"
    else
        log_error "Unrecognized remote format: $CYBERVPS_REMOTE"
        return 1
    fi

    # Optional Retention Policy (Phase 34)
    apply_retention_policy "$backup_dir"
    return 0
}

# Download snapshot from remote
download_snapshot() {
    local target_file="${1:-latest}"
    local dest_dir="${2:-$HOME/cyberbackup/downloads}"
    load_remote_config

    ensure_directory "$dest_dir" 0755

    # If target is an HTTPS URL
    if [[ "$target_file" =~ ^https?:// ]]; then
        log_info "Downloading backup directly from HTTPS URL: $target_file"
        local dl_name
        dl_name="$(basename "$target_file")"
        download_file "$target_file" "$dest_dir/$dl_name" || return 1
        echo "$dest_dir/$dl_name"
        return 0
    fi

    if [ -z "$CYBERVPS_REMOTE" ]; then
        log_error "No remote storage configured."
        return 1
    fi

    log_header "Downloading Backup from Remote"

    if [[ "$CYBERVPS_REMOTE" == *:* ]] && ! [[ "$CYBERVPS_REMOTE" == /* ]]; then
        if ! have_command rclone; then
            log_error "rclone not found"; return 1;
        fi

        if [ "$target_file" = "latest" ]; then
            log_info "Fetching latest metadata..."
            rclone copy "$CYBERVPS_REMOTE/latest.json" "$dest_dir/" 2>/dev/null || true
            if [ -f "$dest_dir/latest.json" ]; then
                target_file="$(grep -E '"backup_file":' "$dest_dir/latest.json" | cut -d'"' -f4 || true)"
            fi
        fi

        [ -z "$target_file" ] && { log_error "Could not determine target backup file"; return 1; }

        log_info "Downloading $target_file from $CYBERVPS_REMOTE..."
        rclone copy "$CYBERVPS_REMOTE/$target_file" "$dest_dir/" || return 1
        rclone copy "$CYBERVPS_REMOTE/SHA256SUMS" "$dest_dir/" 2>/dev/null || true

    elif [ -d "$CYBERVPS_REMOTE" ]; then
        if [ "$target_file" = "latest" ]; then
            if [ -f "$CYBERVPS_REMOTE/latest.json" ]; then
                cp "$CYBERVPS_REMOTE/latest.json" "$dest_dir/"
                target_file="$(grep -E '"backup_file":' "$dest_dir/latest.json" | cut -d'"' -f4 || true)"
            fi
        fi

        [ -z "$target_file" ] && { log_error "Target backup file not found"; return 1; }
        cp "$CYBERVPS_REMOTE/$target_file" "$dest_dir/" || return 1
        [ -f "$CYBERVPS_REMOTE/SHA256SUMS" ] && cp "$CYBERVPS_REMOTE/SHA256SUMS" "$dest_dir/" || true
    fi

    local downloaded_path="$dest_dir/$target_file"
    if [ -f "$downloaded_path" ]; then
        log_ok "Downloaded: $downloaded_path"
        # Verify SHA256 if SHA256SUMS is available
        if [ -f "$dest_dir/SHA256SUMS" ]; then
            log_info "Verifying SHA256..."
            (cd "$dest_dir" && grep "$target_file" SHA256SUMS | sha256sum -c - 2>/dev/null && log_ok "Checksum verified" || log_warn "Checksum mismatch or not in SHA256SUMS")
        fi
        echo "$downloaded_path"
        return 0
    else
        log_error "Download failed."
        return 1
    fi
}

# Apply retention policy safely
apply_retention_policy() {
    local local_dir="$1"

    if [ "$CYBERVPS_KEEP_LOCAL" -gt 0 ]; then
        log_info "Applying local retention policy (keep $CYBERVPS_KEEP_LOCAL latest)..."
        local count=0
        for f in $(find "$local_dir" -maxdepth 1 -name "cybervps-backup-*.tar.*" | sort -r); do
            count=$((count + 1))
            if [ "$count" -gt "$CYBERVPS_KEEP_LOCAL" ]; then
                log_info "Removing old local backup archive: $(basename "$f")"
                rm -f "$f"
            fi
        done
    fi
}
