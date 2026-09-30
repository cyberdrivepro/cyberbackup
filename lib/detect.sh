#!/usr/bin/env bash
# lib/detect.sh — Portable environment and architecture detection for CyberVPS
# Zero hardcoded host assumptions. Fully dynamic identity and capability mapping.

[ -n "${_CYBERVPS_DETECT_SH_LOADED:-}" ] && return 0
_CYBERVPS_DETECT_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/privilege.sh
source "$LIB_DIR/privilege.sh"
# shellcheck source=lib/resources.sh
source "$LIB_DIR/resources.sh"
# shellcheck source=lib/capabilities.sh
source "$LIB_DIR/capabilities.sh"
# shellcheck source=lib/network.sh
source "$LIB_DIR/network.sh"

detect_environment() {
    # Dynamic identity
    CYBER_USER="$(id -un 2>/dev/null || whoami)"
    CYBER_UID="$(id -u 2>/dev/null || echo 1000)"
    CYBER_GID="$(id -g 2>/dev/null || echo 1000)"
    CYBER_HOME="${HOME:-/home/$CYBER_USER}"
    CYBER_HOSTNAME="$(hostname 2>/dev/null || uname -n 2>/dev/null || echo "localhost")"
    CYBER_KERNEL="$(uname -s 2>/dev/null || echo "Linux")"
    CYBER_RAW_ARCH="$(uname -m 2>/dev/null || echo "x86_64")"

    CYBER_PLATFORM="$CYBER_KERNEL"
    case "$CYBER_KERNEL" in MINGW*|MSYS*|CYGWIN*) CYBER_PLATFORM=Windows ;; esac
    detect_privilege

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
    CYBER_DISTRO_NAME="$CYBER_PLATFORM"
    CYBER_DISTRO_PRETTY=""
    CYBER_DISTRO_VERSION="unknown"

    local os_release="${CYBERVPS_ROOT_VIEW:-}/etc/os-release"
    if [ -f "$os_release" ]; then
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
        done < "$os_release"
    fi
    CYBER_DISTRO_PRETTY="${CYBER_DISTRO_PRETTY:-$CYBER_DISTRO_NAME $CYBER_DISTRO_VERSION}"

    # Share architecture/libc parsing with backup compatibility checks.
    CYBER_ARCH="$(normalize_arch "$CYBER_RAW_ARCH")"
    local libc_info
    libc_info="$(detect_libc_info)"
    CYBER_LIBC="${libc_info%%:*}"
    CYBER_LIBC_VERSION="${libc_info#*:}"
    CYBER_LIBC_VERSION="${CYBER_LIBC_VERSION:-unknown}"
    if [ "$CYBER_PLATFORM" != Linux ]; then
        CYBER_MAMBA_ARCH=""
        CYBER_GO_ARCH=""
    fi
    detect_resources
    detect_capabilities

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
    echo "CPUs:         $CYBER_NPROC effective vCPU / $CYBER_HOST_NPROC host-visible threads"
    echo "RAM:          ${CYBER_RAM_TOTAL_MB}MB effective (~${CYBER_RAM_AVAIL_MB}MB available); ${CYBER_HOST_RAM_TOTAL_MB}MB host-visible"
    echo "Cgroups:      $CYBER_CGROUP_VERSION (resource source: $CYBER_RESOURCE_SOURCE)"
    echo "Disk:         ~${CYBER_DISK_FREE_MB}MB free in $CYBER_HOME ($CYBER_DISK_FSTYPE)"
    print_capability_summary
    echo "Backends:     ${CYBER_BACKENDS[*]:-none}"
    echo "==============================="
}

# Export environment variables for consumers
detect_environment
