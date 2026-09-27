#!/usr/bin/env bash
# lib/archive.sh — Archive security validation and safe extraction engine
# Prevents path traversal, absolute path overwrites, malicious symlink escapes,
# and unsafe device node extraction in rootless environments.

[ -n "${_CYBERVPS_ARCHIVE_SH_LOADED:-}" ] && return 0
_CYBERVPS_ARCHIVE_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/logging.sh
source "$LIB_DIR/logging.sh"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"

# Determine archive compression type
get_archive_compression() {
    local archive="$1"
    if [[ "$archive" == *.tar.zst ]] || [[ "$archive" == *.tzst ]]; then
        echo "zstd"
    elif [[ "$archive" == *.tar.gz ]] || [[ "$archive" == *.tgz ]]; then
        echo "gzip"
    elif [[ "$archive" == *.tar.bz2 ]] || [[ "$archive" == *.tbz2 ]]; then
        echo "bzip2"
    elif [[ "$archive" == *.tar.xz ]] || [[ "$archive" == *.txz ]]; then
        echo "xz"
    elif [[ "$archive" == *.tar ]]; then
        echo "none"
    else
        # Inspect magic bytes via file if available
        if have_command file; then
            local ftype
            ftype="$(file -b "$archive" 2>/dev/null || true)"
            case "$ftype" in
                *Zstandard*) echo "zstd" ;;
                *gzip*)      echo "gzip" ;;
                *bzip2*)     echo "bzip2" ;;
                *XZ*)        echo "xz" ;;
                *tar*)       echo "none" ;;
                *)           echo "unknown" ;;
            esac
        else
            echo "unknown"
        fi
    fi
}

# Helper to invoke tar with correct decompressor
_run_tar() {
    local comp="$1"
    shift
    case "$comp" in
        zstd)
            if ! have_command zstd; then
                log_error "zstd decompressor is required but not installed."
                return 1
            fi
            tar -I zstd "$@"
            ;;
        gzip)
            tar -z "$@"
            ;;
        bzip2)
            tar -j "$@"
            ;;
        xz)
            tar -J "$@"
            ;;
        none)
            tar "$@"
            ;;
        *)
            log_error "Unsupported or unknown archive compression format."
            return 1
            ;;
    esac
}

# Check if a symlink target safely stays within the extraction root
_check_symlink_target_safe() {
    local link_path="$1"
    local target="$2"

    # Reject absolute target paths
    if [[ "$target" =~ ^/ ]]; then
        return 1
    fi

    # Calculate directory depth of link_path
    local dir
    dir="$(dirname "$link_path")"
    local depth=0
    if [ "$dir" != "." ] && [ "$dir" != "/" ]; then
        depth="$(awk -F'/' '{print NF}' <<< "$dir")"
    fi

    # Count how many leading '../' in target
    local up_count=0
    local rem="$target"
    while [[ "$rem" =~ ^\.\./ ]]; do
        up_count=$((up_count + 1))
        rem="${rem#../}"
    done
    [ "$rem" = ".." ] && up_count=$((up_count + 1))

    if [ "$up_count" -gt "$depth" ]; then
        return 1 # Escapes extraction root
    fi

    # Disallow symlinks referencing suspicious absolute-looking names inside
    if [[ "$target" =~ (^|/)\.(ssh|gnupg|config/shadow)(/|$) ]]; then
        return 1
    fi

    return 0
}

# Validate archive security without extracting
validate_archive_security() {
    local archive="$1"

    if [ ! -f "$archive" ]; then
        log_error "Archive file not found: $archive"
        return 1
    fi

    if [ ! -s "$archive" ]; then
        log_error "Archive file is empty: $archive"
        return 1
    fi

    local comp
    comp="$(get_archive_compression "$archive")"
    if [ "$comp" = "unknown" ]; then
        log_error "Unrecognized archive compression for: $archive"
        return 1
    fi

    log_debug "Validating archive security: $(basename "$archive") (compression: $comp)"

    # List members
    local members
    members="$(_run_tar "$comp" -tf "$archive" 2>/dev/null)" || {
        log_error "Failed to read table of contents from archive: $archive"
        return 1
    }

    if [ -z "$members" ]; then
        log_error "Archive contains no members: $archive"
        return 1
    fi

    # Check 1: Reject absolute paths
    if echo "$members" | grep -E '^/' >/dev/null; then
        local bad_abs
        bad_abs="$(echo "$members" | grep -E '^/' | head -3 | tr '\n' ' ')"
        log_error "SECURITY ALERT: Archive contains dangerous absolute paths: $bad_abs"
        return 1
    fi

    # Check 2: Reject path traversal (..)
    if echo "$members" | grep -E '(^|/)\.\.(/|$)' >/dev/null; then
        local bad_trav
        bad_trav="$(echo "$members" | grep -E '(^|/)\.\.(/|$)' | head -3 | tr '\n' ' ')"
        log_error "SECURITY ALERT: Archive contains path traversal sequences (..): $bad_trav"
        return 1
    fi

    # Check 3: Inspect detailed listing for device nodes and malicious symlinks
    local details
    details="$(_run_tar "$comp" -tvf "$archive" 2>/dev/null)" || {
        log_error "Failed to read verbose listing from archive: $archive"
        return 1
    }

    # Reject character or block device nodes or fifos
    if echo "$details" | grep -E '^[cbp]' >/dev/null; then
        log_error "SECURITY ALERT: Archive contains dangerous device node or FIFO."
        return 1
    fi

    # Inspect symlinks (lines starting with 'l')
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [[ "$line" =~ ^l ]]; then
            local before_arrow="${line% -> *}"
            local link_target="${line#* -> }"
            local link_name
            link_name="$(echo "$before_arrow" | awk '{ $1=$2=$3=$4=$5=""; sub(/^[ \t]+/, ""); print }')"

            if ! _check_symlink_target_safe "$link_name" "$link_target"; then
                log_error "SECURITY ALERT: Archive contains unsafe escaping symlink: $link_name -> $link_target"
                return 1
            fi
        fi
    done <<< "$details"

    log_ok "Archive security scan passed: $archive"
    return 0
}

# Safe extraction of archive into staging directory
extract_archive_safe() {
    local archive="$1"
    local dest_dir="$2"

    [ ! -f "$archive" ] && { log_error "Archive not found: $archive"; return 1; }
    ensure_directory "$dest_dir" 0700

    # Mandatory security validation before extraction
    validate_archive_security "$archive" || {
        log_error "Extraction aborted: Archive failed security validation."
        return 1
    }

    local comp
    comp="$(get_archive_compression "$archive")"

    log_info "Extracting archive safely into: $dest_dir"
    if ! _run_tar "$comp" -xf "$archive" -C "$dest_dir" --no-same-owner --delay-directory-restore; then
        log_error "Archive extraction failed."
        return 1
    fi

    log_ok "Archive extracted successfully."
    return 0
}
