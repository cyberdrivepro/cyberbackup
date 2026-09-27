#!/usr/bin/env bash
# lib/detect.sh — Portable environment and architecture detection for CyberVPS
# Zero hardcoded host assumptions. Fully dynamic identity and capability mapping.

[ -n "${_CYBERVPS_DETECT_SH_LOADED:-}" ] && return 0
_CYBERVPS_DETECT_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"

detect_environment() {
    # Dynamic identity
    CYBER_USER="$(id -un 2>/dev/null || whoami)"
    CYBER_UID="$(id -u 2>/dev/null || echo 1000)"
    CYBER_GID="$(id -g 2>/dev/null || echo 1000)"
    CYBER_HOME="${HOME:-/home/$CYBER_USER}"
    CYBER_HOSTNAME="$(hostname 2>/dev/null || uname -n 2>/dev/null || echo "localhost")"
    CYBER_KERNEL="$(uname -s 2>/dev/null || echo "Linux")"
    CYBER_RAW_ARCH="$(uname -m 2>/dev/null || echo "x86_64")"

    # Architecture Normalization
    case "$CYBER_RAW_ARCH" in
        x86_64|amd64)
            CYBER_ARCH="x86_64"
            CYBER_MAMBA_ARCH="linux-64"
            CYBER_GO_ARCH="linux-amd64"
            CYBER_CLOUDFLARED_ARCH="amd64"
            ;;
        aarch64|arm64)
            CYBER_ARCH="aarch64"
            CYBER_MAMBA_ARCH="linux-aarch64"
            CYBER_GO_ARCH="linux-arm64"
            CYBER_CLOUDFLARED_ARCH="arm64"
            ;;
        armv7l|armhf)
            CYBER_ARCH="armv7l"
            CYBER_MAMBA_ARCH=""
            CYBER_GO_ARCH="linux-armv6l"
            CYBER_CLOUDFLARED_ARCH="arm"
            log_warn "32-bit ARM detected ($CYBER_RAW_ARCH); Micromamba is unsupported on this architecture."
            ;;
        *)
            CYBER_ARCH="$CYBER_RAW_ARCH"
            CYBER_MAMBA_ARCH=""
            CYBER_GO_ARCH=""
            CYBER_CLOUDFLARED_ARCH=""
            log_warn "Architecture '$CYBER_RAW_ARCH' may have limited binary support."
            ;;
    esac

    # OS & Distribution Detection (/etc/os-release)
    CYBER_DISTRO_ID="unknown"
    CYBER_DISTRO_NAME="Linux"
    CYBER_DISTRO_VERSION="unknown"

    if [ -f /etc/os-release ]; then
        # Read without sourcing to prevent side effects
        while IFS='=' read -r k v; do
            v="${v%\"}"
            v="${v#\"}"
            case "$k" in
                ID) CYBER_DISTRO_ID="$v" ;;
                NAME) CYBER_DISTRO_NAME="$v" ;;
                VERSION_ID) CYBER_DISTRO_VERSION="$v" ;;
                PRETTY_NAME) CYBER_DISTRO_PRETTY="$v" ;;
            esac
        done < /etc/os-release
    fi
    CYBER_DISTRO_PRETTY="${CYBER_DISTRO_PRETTY:-$CYBER_DISTRO_NAME $CYBER_DISTRO_VERSION}"

    # C Runtime / Libc Detection
    CYBER_LIBC="glibc"
    CYBER_LIBC_VERSION="unknown"
    if have_command ldd; then
        local ldd_out
        ldd_out="$(ldd --version 2>&1 | head -n 1 || true)"
        if echo "$ldd_out" | grep -iq "musl"; then
            CYBER_LIBC="musl"
            CYBER_LIBC_VERSION="$(echo "$ldd_out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")"
        elif echo "$ldd_out" | grep -iqE "gnu|glibc"; then
            CYBER_LIBC="glibc"
            CYBER_LIBC_VERSION="$(echo "$ldd_out" | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "unknown")"
        fi
    elif have_command getconf; then
        local gc
        gc="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
        if [ -n "$gc" ]; then
            CYBER_LIBC="glibc"
            CYBER_LIBC_VERSION="$(echo "$gc" | awk '{print $NF}')"
        fi
    fi

    # Hardware resources
    CYBER_NPROC="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)"
    CYBER_RAM_TOTAL_MB="unknown"
    CYBER_RAM_AVAIL_MB="unknown"
    if [ -f /proc/meminfo ]; then
        local mem_kb
        mem_kb="$(grep -i 'MemTotal:' /proc/meminfo | awk '{print $2}')"
        CYBER_RAM_TOTAL_MB="$((mem_kb / 1024))"
        local avail_kb
        avail_kb="$(grep -i 'MemAvailable:' /proc/meminfo | awk '{print $2}' || true)"
        if [ -n "$avail_kb" ]; then
            CYBER_RAM_AVAIL_MB="$((avail_kb / 1024))"
        fi
    fi

    # Disk Space in HOME
    CYBER_DISK_FREE_MB="unknown"
    if have_command df; then
        CYBER_DISK_FREE_MB="$(df -m "$CYBER_HOME" 2>/dev/null | tail -1 | awk '{print $4}' || echo "unknown")"
    fi

    # Detect Available Service Persistence Backends
    CYBER_BACKENDS=()
    if have_command systemctl && systemctl --user list-units >/dev/null 2>&1; then
        CYBER_BACKENDS+=("systemd-user")
    fi
    if have_command tmux; then
        CYBER_BACKENDS+=("tmux")
    fi
    if have_command screen; then
        CYBER_BACKENDS+=("screen")
    fi
    if have_command nohup; then
        CYBER_BACKENDS+=("nohup")
    fi

    log_debug "Detected: user=$CYBER_USER arch=$CYBER_ARCH distro=$CYBER_DISTRO_ID libc=$CYBER_LIBC ($CYBER_LIBC_VERSION)"
}

# Print summary to terminal
print_system_summary() {
    detect_environment
    echo "=== CyberVPS System Profile ==="
    echo "Host:         $CYBER_HOSTNAME"
    echo "User:         $CYBER_USER (uid=$CYBER_UID, gid=$CYBER_GID)"
    echo "Home:         $CYBER_HOME"
    echo "OS / Distro:  $CYBER_DISTRO_PRETTY"
    echo "Architecture: $CYBER_ARCH (kernel: $CYBER_KERNEL)"
    echo "C Library:    $CYBER_LIBC $CYBER_LIBC_VERSION"
    echo "CPUs:         $CYBER_NPROC cores"
    echo "RAM:          ${CYBER_RAM_TOTAL_MB}MB total (~${CYBER_RAM_AVAIL_MB}MB available)"
    echo "Disk:         ~${CYBER_DISK_FREE_MB}MB free in $CYBER_HOME"
    echo "Backends:     ${CYBER_BACKENDS[*]:-none}"
    echo "==============================="
}

# Export environment variables for consumers
detect_environment
