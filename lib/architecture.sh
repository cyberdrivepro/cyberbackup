#!/usr/bin/env bash
# lib/architecture.sh — CPU architecture and C library compatibility validator
# Evaluates binary compatibility between source snapshot and target system.

[ -n "${_CYBERVPS_ARCHITECTURE_SH_LOADED:-}" ] && return 0
_CYBERVPS_ARCHITECTURE_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/logging.sh
source "$LIB_DIR/logging.sh"

# Normalize raw machine architecture string
normalize_arch() {
    local raw="${1:-$(uname -m 2>/dev/null || echo "unknown")}"
    case "$raw" in
        x86_64|amd64|x64)
            echo "x86_64"
            ;;
        aarch64|arm64|armv8*)
            echo "aarch64"
            ;;
        armv7*|armhf)
            echo "armv7l"
            ;;
        i386|i686|x86)
            echo "x86"
            ;;
        riscv64)
            echo "riscv64"
            ;;
        s390x)
            echo "s390x"
            ;;
        ppc64le)
            echo "ppc64le"
            ;;
        *)
            echo "$raw"
            ;;
    esac
}

# Detect C standard library implementation and version
detect_libc_info() {
    local libc_type="unknown"
    local libc_ver=""

    if command -v ldd >/dev/null 2>&1; then
        local ldd_out
        ldd_out="$(ldd --version 2>&1 || true)"
        if [[ "$ldd_out" =~ (GNU|GLIBC) ]]; then
            libc_type="glibc"
            libc_ver="$(echo "$ldd_out" | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "")"
        elif [[ "$ldd_out" =~ musl ]]; then
            libc_type="musl"
            libc_ver="$(echo "$ldd_out" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")"
        fi
    elif [ -f /lib/ld-musl-*.so.1 ] || [ -f /lib64/ld-musl-*.so.1 ]; then
        libc_type="musl"
    fi

    echo "${libc_type}:${libc_ver}"
}

# Compare two semantic version strings (returns: 0 if equal, 1 if v1 > v2, 2 if v1 < v2)
compare_versions() {
    local v1="$1"
    local v2="$2"
    if [ "$v1" = "$v2" ]; then
        return 0
    fi
    local sorted
    sorted="$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -1)"
    if [ "$sorted" = "$v1" ]; then
        return 2 # v1 < v2
    else
        return 1 # v1 > v2
    fi
}

# Check if target system can execute binaries built on source system
# Returns:
#   0: Fully binary compatible
#   1: Incompatible (different architecture, or musl vs glibc, or target libc older than source)
check_binary_compatibility() {
    local src_arch="$1"
    local dst_arch="$2"
    local src_libc="${3:-glibc}"
    local src_libc_ver="${4:-}"
    local dst_libc="${5:-glibc}"
    local dst_libc_ver="${6:-}"

    # Architecture check
    local norm_src
    local norm_dst
    norm_src="$(normalize_arch "$src_arch")"
    norm_dst="$(normalize_arch "$dst_arch")"

    if [ "$norm_src" != "$norm_dst" ]; then
        log_warn "Architecture mismatch: Source is $norm_src, Target is $norm_dst."
        return 1
    fi

    # Libc implementation check
    if [ "$src_libc" != "$dst_libc" ]; then
        log_warn "Libc implementation mismatch: Source is $src_libc, Target is $dst_libc."
        return 1
    fi

    # Libc version check (if glibc: target libc cannot be older than source libc)
    if [ "$src_libc" = "glibc" ] && [ -n "$src_libc_ver" ] && [ -n "$dst_libc_ver" ]; then
        local cmp=0
        compare_versions "$src_libc_ver" "$dst_libc_ver" || cmp=$?
        if [ "$cmp" -eq 1 ]; then
            # Source libc version > Target libc version
            log_warn "Target glibc version ($dst_libc_ver) is older than source glibc ($src_libc_ver). Binaries may fail to load."
            return 1
        fi
    fi

    log_ok "Binary compatibility verified: $norm_src ($dst_libc $dst_libc_ver)"
    return 0
}
