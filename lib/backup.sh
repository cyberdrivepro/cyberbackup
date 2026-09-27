#!/usr/bin/env bash
# lib/backup.sh — Portable backup engine for CyberVPS (Format Version 2)
# Handles manifest generation, safe exclusion of secrets and disposable caches,
# archive creation (tar+zstd / tar+gz), SHA256 integrity, and machine-readable metadata.

[ -n "${_CYBERVPS_BACKUP_SH_LOADED:-}" ] && return 0
_CYBERVPS_BACKUP_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=lib/ports.sh
source "$LIB_DIR/ports.sh"
# shellcheck source=lib/archive.sh
source "$LIB_DIR/archive.sh"

CYBERVPS_BACKUP_FORMAT=2

# Discover user projects under ~/projects and ~/examples
discover_projects() {
    local out_json="$1"
    local proj_dirs=()

    for base in "${HOME}/projects" "${HOME}/examples"; do
        if [ -d "$base" ]; then
            for p in "$base"/*; do
                if [ -d "$p" ]; then
                    proj_dirs+=("$p")
                fi
            done
        fi
    done

    # Generate JSON array of projects
    printf '[\n' > "$out_json"
    local first=1
    for p in "${proj_dirs[@]}"; do
        [ "$first" -eq 1 ] || printf ',\n' >> "$out_json"
        first=0
        local name
        name="$(basename "$p")"
        local p_type="generic"
        [ -f "$p/package.json" ] && p_type="node"
        [ -f "$p/requirements.txt" ] || [ -f "$p/pyproject.toml" ] && p_type="python"
        [ -f "$p/Cargo.toml" ] && p_type="rust"
        [ -f "$p/go.mod" ] && p_type="go"
        printf '  {\n    "name": "%s",\n    "path": "%s",\n    "type": "%s"\n  }' "$name" "$p" "$p_type" >> "$out_json"
    done
    printf '\n]\n' >> "$out_json"
}

# Generate reproducible runtime manifests
generate_runtime_manifests() {
    local manifest_dir="$1"
    ensure_directory "$manifest_dir"

    log_info "Generating environment and runtime manifests..."

    # System manifest
    cat > "$manifest_dir/system.json" <<EOF
{
  "format_version": $CYBERVPS_BACKUP_FORMAT,
  "cybervps_version": "$CYBERVPS_VERSION",
  "created_at": "$(date --iso-8601=seconds 2>/dev/null || date)",
  "source_user": "$CYBER_USER",
  "source_uid": $CYBER_UID,
  "source_gid": $CYBER_GID,
  "source_home": "$CYBER_HOME",
  "source_hostname": "$CYBER_HOSTNAME",
  "architecture": "$CYBER_ARCH",
  "raw_arch": "$CYBER_RAW_ARCH",
  "kernel": "$CYBER_KERNEL",
  "distro_id": "$CYBER_DISTRO_ID",
  "distro_name": "$CYBER_DISTRO_NAME",
  "distro_version": "$CYBER_DISTRO_VERSION",
  "distro_pretty": "$CYBER_DISTRO_PRETTY",
  "libc": "$CYBER_LIBC",
  "libc_version": "$CYBER_LIBC_VERSION"
}
EOF

    # Python & Pip
    if have_command python; then
        python --version > "$manifest_dir/python-version.txt" 2>&1 || true
    fi
    if have_command pip; then
        pip freeze > "$manifest_dir/pip-freeze.txt" 2>/dev/null || true
    fi

    # Micromamba
    if have_command micromamba; then
        micromamba env list > "$manifest_dir/micromamba-list.txt" 2>/dev/null || true
        local env_name="${CYBERVPS_ENV_NAME:-hosting}"
        micromamba env export -n "$env_name" > "$manifest_dir/micromamba-env.yml" 2>/dev/null || true
        micromamba list -n "$env_name" --explicit > "$manifest_dir/micromamba-explicit.txt" 2>/dev/null || true
    fi

    # Node, npm, pnpm, yarn, pm2
    if have_command node; then
        node --version > "$manifest_dir/node-version.txt" 2>&1 || true
    fi
    if have_command npm; then
        npm --version > "$manifest_dir/npm-version.txt" 2>&1 || true
        npm list -g --depth=0 --json > "$manifest_dir/npm-global.json" 2>/dev/null || true
    fi
    if have_command pnpm; then
        pnpm --version > "$manifest_dir/pnpm-version.txt" 2>&1 || true
    fi
    if have_command yarn; then
        yarn --version > "$manifest_dir/yarn-version.txt" 2>&1 || true
    fi
    if have_command pm2; then
        pm2 dump >/dev/null 2>&1 || true
    fi

    # Rust & Go
    if have_command rustc; then
        rustc --version > "$manifest_dir/rust-version.txt" 2>&1 || true
    fi
    if have_command cargo; then
        cargo --list > "$manifest_dir/cargo-installed.txt" 2>/dev/null || true
    fi
    if have_command go; then
        go version > "$manifest_dir/go-version.txt" 2>&1 || true
        go env > "$manifest_dir/go-env.txt" 2>&1 || true
    fi

    # Ports & Projects
    [ -f "$PORTS_CONFIG_FILE" ] && cp "$PORTS_CONFIG_FILE" "$manifest_dir/ports.env"
    discover_projects "$manifest_dir/projects.json"

    log_ok "Runtime manifests generated successfully"
}

# Core backup routine
create_cybervps_backup() {
    local opt_include_shared="${1:-0}"
    local opt_encrypt_secrets="${2:-0}"
    local opt_dry_run="${3:-0}"
    local dest_dir="${4:-$HOME/cyberbackup/downloads}"

    ensure_directory "$dest_dir" 0755
    detect_environment

    local date_stamp
    date_stamp="$(date +%Y%m%d-%H%M%S)"
    local archive_ext="tar.zst"
    have_command zstd || archive_ext="tar.gz"

    local archive_name="cybervps-backup-${date_stamp}.${archive_ext}"
    local archive_path="${dest_dir}/${archive_name}"

    log_header "Creating CyberVPS Backup Snapshot"
    log_info "Archive: $archive_name"
    log_info "Destination: $dest_dir"

    # Staging manifest directory
    local staging_root="${dest_dir}/staging-${date_stamp}"
    local staging_manifests="${staging_root}/manifests"
    generate_runtime_manifests "$staging_manifests"

    # Build inclusion file list (relative to $HOME)
    local file_list="${dest_dir}/filelist-${date_stamp}.txt"
    > "$file_list"

    # Core portable configuration and metadata paths (relative to $HOME)
    local include_rel_paths=(
        "bin"
        "config"
        "services"
        "projects"
        "examples"
        ".pm2/dump.pm2"
        ".bashrc"
        ".profile"
        ".bash_aliases"
        ".bash_logout"
        ".config/cybervps"
    )

    for p in "${include_rel_paths[@]}"; do
        if [ -e "${HOME}/$p" ]; then
            echo "$p" >> "$file_list"
        fi
    done

    # Exclude patterns file
    local exclude_file="${dest_dir}/excludes-${date_stamp}.txt"
    cat << 'EXCLUDES' > "$exclude_file"
# Reproducible package & build caches
node_modules
.cache
.npm
.pnpm-store
__pycache__
*.pyc
*.pyo
*.egg-info
dist
build
target
*.rs.bk
*.swp
*~
.DS_Store
Thumbs.db
pkgs

# Runtime, sockets, PIDs, and lock files
*.pid
*.sock
*.lock
pm2.log
pm2.pid
rpc.sock
pub.sock
daemon.json
dump.rdb
appendonly.aof
appendonlydir
client_body_temp
proxy_temp
fastcgi_temp
uwsgi_temp
scgi_temp

# Secrets and credentials
.env
.env.*
remote.conf
rclone.conf
id_rsa
id_rsa.pub
id_ed25519
id_ed25519.pub
*.key
*.pem
credentials*
tokens*

# Large external storage
shared
EXCLUDES

    if [ "$opt_dry_run" -eq 1 ]; then
        log_warn "DRY-RUN MODE: Simulating backup creation"
        log_info "Included relative base directories:"
        cat "$file_list"
        rm -rf "$staging_root" "$file_list" "$exclude_file"
        return 0
    fi

    log_info "Compressing relative archive ($archive_ext)..."
    if have_command zstd; then
        tar --exclude-from="$exclude_file" -C "$staging_root" manifests -C "$HOME" --files-from="$file_list" -I 'zstd -3 -T0' -cf "$archive_path"
    else
        tar --exclude-from="$exclude_file" -C "$staging_root" manifests -C "$HOME" --files-from="$file_list" -czf "$archive_path"
    fi

    # Verify archive integrity and security scan immediately
    log_info "Verifying archive integrity and security profile..."
    if ! validate_archive_security "$archive_path"; then
        log_error "Backup archive failed security validation"
        rm -rf "$staging_root" "$file_list" "$exclude_file"
        return 1
    fi
    log_ok "Archive integrity and security verified"

    # Compute SHA256
    local sha256
    sha256="$(sha256sum "$archive_path" | awk '{print $1}')"
    local size_bytes
    size_bytes="$(stat -c%s "$archive_path" 2>/dev/null || stat -f%z "$archive_path" 2>/dev/null || echo 0)"

    # Write metadata latest.json atomically
    local metadata_file="${dest_dir}/latest.json"
    cat > "${metadata_file}.tmp" <<EOF
{
  "backup_file": "$archive_name",
  "archive_path": "$archive_path",
  "creation_timestamp": "$(date --iso-8601=seconds 2>/dev/null || date)",
  "backup_format_version": $CYBERVPS_BACKUP_FORMAT,
  "cybervps_version": "$CYBERVPS_VERSION",
  "sha256": "$sha256",
  "size_bytes": $size_bytes,
  "source_user": "$CYBER_USER",
  "source_home": "$CYBER_HOME",
  "source_hostname": "$CYBER_HOSTNAME",
  "architecture": "$CYBER_ARCH",
  "kernel": "$CYBER_KERNEL",
  "distro_id": "$CYBER_DISTRO_ID",
  "distro_pretty": "$CYBER_DISTRO_PRETTY",
  "libc": "$CYBER_LIBC",
  "shared_included": $opt_include_shared,
  "secrets_encrypted": $opt_encrypt_secrets
}
EOF
    mv -f "${metadata_file}.tmp" "$metadata_file"

    # Update SHA256SUMS
    (cd "$dest_dir" && sha256sum "$archive_name" >> SHA256SUMS && sort -u SHA256SUMS -o SHA256SUMS)

    # Optional Shared Data Archive (Phase 23)
    if [ "$opt_include_shared" -eq 1 ] && [ -d "${HOME}/shared" ]; then
        local shared_archive="${dest_dir}/cybervps-shared-${date_stamp}.${archive_ext}"
        local shared_size
        shared_size="$(du -sh "${HOME}/shared" 2>/dev/null | awk '{print $1}')"
        log_header "Archiving Shared Data ($shared_size)"
        if have_command zstd; then
            tar -I 'zstd -1 -T0' -cf "$shared_archive" -C "$HOME" shared
        else
            tar -czf "$shared_archive" -C "$HOME" shared
        fi
        log_ok "Shared data archived: $shared_archive"
    fi

    # Optional Encrypted Secrets Backup (Phase 24)
    if [ "$opt_encrypt_secrets" -eq 1 ]; then
        local sec_tar="${dest_dir}/cybervps-secrets-${date_stamp}.tar"
        local sec_enc="${dest_dir}/cybervps-secrets-${date_stamp}.enc"
        log_header "Creating Encrypted Secrets Archive"
        local sec_files=()
        for f in "${HOME}"/.env* "${HOME}/config"/*.conf "${HOME}/.ssh"/id_*; do
            [ -f "$f" ] && sec_files+=("$f")
        done
        if [ "${#sec_files[@]}" -gt 0 ]; then
            tar -cf "$sec_tar" "${sec_files[@]}" 2>/dev/null || true
            if have_command openssl; then
                echo "Please enter passphrase for encrypted secrets:"
                openssl enc -aes-256-cbc -pbkdf2 -salt -in "$sec_tar" -out "$sec_enc"
                rm -f "$sec_tar"
                chmod 0600 "$sec_enc"
                log_ok "Encrypted secrets saved to: $sec_enc (chmod 0600)"
            else
                log_error "openssl not available; cannot encrypt secrets."
                rm -f "$sec_tar"
            fi
        else
            log_info "No sensitive files found to encrypt."
        fi
    fi

    # Clean temporary files
    rm -rf "$staging_root" "$file_list" "$exclude_file"

    log_header "Backup Summary"
    log_ok "Archive created: $archive_path"
    log_ok "Archive size: $(du -h "$archive_path" | awk '{print $1}')"
    log_ok "SHA256: $sha256"
    log_ok "Metadata: $metadata_file"
    return 0
}
