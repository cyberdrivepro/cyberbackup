#!/usr/bin/env bash
# lib/proot.sh — PRoot & Virtual Root Guest Runtime for CyberVPS
# Provides transparent root execution (root@cybervps:~#) for unprivileged / rootless environments.
# Uses PRoot ptrace system call emulation. PROOT_NO_SECCOMP=1 is used for container compatibility.

[ -n "${_CYBERVPS_PROOT_SH_LOADED:-}" ] && return 0
_CYBERVPS_PROOT_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/download.sh
source "$LIB_DIR/download.sh"
# shellcheck source=lib/ui.sh
source "$LIB_DIR/ui.sh"

cyber_proot_arch() {
    local arch="${CYBER_ARCH:-$(uname -m)}"
    case "$arch" in
        x86_64|amd64) echo "x86_64" ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7l|armhf|arm) echo "arm" ;;
        i686|i386) echo "i386" ;;
        *) echo "$arch" ;;
    esac
}

cyber_proot_find_bin() {
    if [ -n "${CYBERVPS_PROOT_BIN:-}" ] && [ -x "$CYBERVPS_PROOT_BIN" ]; then
        echo "$CYBERVPS_PROOT_BIN"
        return 0
    fi
    if command -v proot >/dev/null 2>&1; then
        command -v proot
        return 0
    fi
    if [ -x "$HOME/.local/bin/proot" ]; then
        echo "$HOME/.local/bin/proot"
        return 0
    fi
    if [ -x "$CYBERVPS_ROOT/bin/proot" ]; then
        echo "$CYBERVPS_ROOT/bin/proot"
        return 0
    fi
    return 1
}

cyber_proot_test_bin() {
    local bin="$1"
    [ -x "$bin" ] || return 1
    "$bin" --version >/dev/null 2>&1 || "$bin" --help >/dev/null 2>&1 || return 1
    return 0
}

cyber_proot_ensure_bin() {
    local bin
    if bin="$(cyber_proot_find_bin)" && cyber_proot_test_bin "$bin"; then
        return 0
    fi

    # Try native distro package manager first if admin access is available
    if [ "${CYBER_CAN_ADMIN:-false}" = true ] && [ "${CYBER_SYSTEM_PACKAGES:-UNAVAILABLE}" = AVAILABLE ]; then
        if [ "${CYBER_PACKAGE_MANAGER:-}" = apt-get ] || [ "${CYBER_PACKAGE_MANAGER:-}" = apt ]; then
            log_info "Attempting native proot installation via system package manager..."
            cyber_run_privileged env DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
            cyber_run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends proot >/dev/null 2>&1 || true
            if bin="$(cyber_proot_find_bin)" && cyber_proot_test_bin "$bin"; then
                log_ok "Native PRoot package ready at $bin"
                return 0
            fi
        fi
    fi

    log_info "Acquiring portable PRoot engine for architecture $(cyber_proot_arch)..."
    local arch
    arch="$(cyber_proot_arch)"
    local dest_dir="${HOME}/.local/bin"
    ensure_directory "$dest_dir" 0755
    local dest_file="$dest_dir/proot"

    local mirrors=()
    if [ "$arch" = "x86_64" ]; then
        mirrors+=(
            "https://proot.gitlab.io/proot/bin/proot"
            "https://raw.githubusercontent.com/proot-me/proot-static-builds/master/static/proot-x86_64"
        )
    else
        mirrors+=(
            "https://raw.githubusercontent.com/proot-me/proot-static-builds/master/static/proot-${arch}"
        )
    fi

    local downloaded=0
    local temp_dest
    temp_dest="$(mktemp "${dest_file}.dl.XXXXXX")" || return 8
    for url in "${mirrors[@]}"; do
        log_debug "Attempting proot download from: $url"
        if cyber_download "$url" "$temp_dest"; then
            chmod 0755 "$temp_dest" 2>/dev/null || true
            if [ -s "$temp_dest" ] && cyber_proot_test_bin "$temp_dest"; then
                mv -f "$temp_dest" "$dest_file"
                downloaded=1
                break
            fi
        fi
        : > "$temp_dest"
    done
    rm -f "$temp_dest"

    if [ "$downloaded" -eq 1 ]; then
        log_ok "Portable PRoot engine ready at $dest_file"
        export PATH="$dest_dir:$PATH"
        return 0
    fi

    log_warn "Could not acquire a functional PRoot binary for architecture $arch."
    return 3
}

cyber_guest_dir() {
    local name="${1:-main}"
    cyber_validate_name "$name" || name="main"
    echo "${CYBERVPS_GUEST_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/cybervps/guests/$name}"
}

cyber_guest_is_ready() {
    local name="${1:-main}"
    local gdir
    gdir="$(cyber_guest_dir "$name")"
    [ -d "$gdir" ] && { [ -x "$gdir/bin/sh" ] || [ -x "$gdir/bin/bash" ]; }
}

cyber_guest_setup_fs() {
    local gdir="$1"
    mkdir -p "$gdir" || return 1

    mkdir -p "$gdir"/{proc,sys,dev,dev/pts,dev/shm,tmp,root,root/host,etc,etc/apt/apt.conf.d,home}
    chmod 1777 "$gdir/tmp" 2>/dev/null || true

    # Configure DNS
    cat > "$gdir/etc/resolv.conf" << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 1.0.0.1
EOF

    # Configure hosts
    cat > "$gdir/etc/hosts" << 'EOF'
127.0.0.1 localhost cybervps
::1 localhost ip6-localhost ip6-loopback
EOF

    # Configure Debian/Ubuntu APT options for non-interactive user-space execution
    cat > "$gdir/etc/apt/apt.conf.d/99cybervps" << 'EOF'
Acquire::Languages "none";
APT::Install-Recommends "0";
APT::Install-Suggests "0";
DPkg::Options {
    "--force-confdef";
    "--force-confold";
};
EOF

    # Configure basic environment
    cat > "$gdir/etc/environment" << 'EOF'
DEBIAN_FRONTEND=noninteractive
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF

    # Configure root bashrc
    cat > "$gdir/root/.bashrc" << 'EOF'
export PS1='\[\033[01;32m\]root@cybervps\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]# '
export TERM="${TERM:-xterm-256color}"
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias host='exit'
EOF

    return 0
}

cyber_guest_install_rootfs() {
    local name="${1:-main}"
    local distro="${2:-debian}"
    local gdir
    gdir="$(cyber_guest_dir "$name")"

    if cyber_guest_is_ready "$name"; then
        log_debug "Guest '$name' rootfs already exists at $gdir"
        return 0
    fi

    cyber_proot_ensure_bin || return 3

    log_info "Initializing virtual root environment for guest '$name' ($distro)..."
    ensure_directory "$gdir" 0755

    local arch
    arch="$(cyber_proot_arch)"
    local deb_arch="amd64"
    case "$arch" in
        x86_64) deb_arch="amd64" ;;
        aarch64) deb_arch="arm64" ;;
        arm) deb_arch="armhf" ;;
        i386) deb_arch="i386" ;;
    esac

    local tmp_tarball
    tmp_tarball="$(mktemp "${TMPDIR:-/tmp}/cybervps-rootfs-XXXXXX.tar.xz")"

    if [ -n "${CYBERVPS_ROOTFS_TARBALL:-}" ] && [ -f "$CYBERVPS_ROOTFS_TARBALL" ]; then
        cp "$CYBERVPS_ROOTFS_TARBALL" "$tmp_tarball"
    else
        local mirrors=(
            "https://raw.githubusercontent.com/cyberdrivepro/cyberroot/main/rootfs/debian-minimal-${arch}.tar.xz"
            "https://github.com/debuerreotype/docker-debian-artifacts/raw/dist-${deb_arch}/stable/rootfs.tar.xz"
            "https://raw.githubusercontent.com/cyberdrivepro/cyberroot/main/rootfs/ubuntu-noble-minimal-${arch}.tar.xz"
        )
        local downloaded=0
        for url in "${mirrors[@]}"; do
            log_info "Downloading rootfs from: $url"
            if cyber_download "$url" "$tmp_tarball"; then
                downloaded=1
                break
            fi
        done
        if [ "$downloaded" -ne 1 ]; then
            rm -f "$tmp_tarball"
            log_error "Failed to download minimal rootfs archive."
            return 4
        fi
    fi

    log_info "Extracting rootfs filesystem into $gdir..."
    tar -xf "$tmp_tarball" -C "$gdir" --exclude="dev/*" 2>/dev/null || tar -xf "$tmp_tarball" -C "$gdir" || {
        rm -f "$tmp_tarball"
        log_error "Failed to extract rootfs archive."
        return 8
    }
    rm -f "$tmp_tarball"

    cyber_guest_setup_fs "$gdir"
    log_ok "Virtual root filesystem initialized successfully."

    # Update guest APT indices
    log_info "Updating package lists inside virtual root..."
    cyber_guest_exec "$name" -- apt-get update -y || {
        log_warn "Initial apt-get update completed with warnings; continuing."
    }

    return 0
}

cyber_guest_exec() {
    local name="main"
    if [ "$#" -gt 0 ] && [ "$1" != "--" ]; then
        name="$1"
        shift
    fi
    [ "$#" -gt 0 ] && [ "$1" = "--" ] && shift

    local gdir
    gdir="$(cyber_guest_dir "$name")"
    if [ ! -d "$gdir" ]; then
        log_error "Guest '$name' directory does not exist: $gdir"
        return 2
    fi

    local proot_bin
    proot_bin="$(cyber_proot_find_bin)" || {
        log_error "PRoot binary not available."
        return 3
    }

    local binds=(
        -b /proc:/proc
        -b /sys:/sys
        -b /dev:/dev
        -b /dev/pts:/dev/pts
        -b /dev/shm:/dev/shm
        -b /etc/resolv.conf:/etc/resolv.conf
        -b "$HOME":/root/host
    )

    PROOT_NO_SECCOMP=1 "$proot_bin" \
        -0 \
        -r "$gdir" \
        "${binds[@]}" \
        -w /root \
        /usr/bin/env -i \
            HOME=/root \
            USER=root \
            LOGNAME=root \
            TERM="${TERM:-xterm-256color}" \
            DEBIAN_FRONTEND=noninteractive \
            PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
            "$@"
}

cyber_guest_shell() {
    detect_environment
    if [ "${CYBER_PRIVILEGE_MODE:-ROOTLESS}" = "ROOT" ] || [ "${CYBER_PRIVILEGE_MODE:-ROOTLESS}" = "CONTAINER_ROOT" ] || [ "${CYBER_IS_ROOT:-false}" = true ]; then
        echo -e "\n${C_PRIMARY}${C_BOLD}CyberVPS Host Shell (Native Root)${C_RESET}"
        echo -e "${C_TEXT_MUTED}Active Mode: ${C_TEXT}${CYBER_PRIVILEGE_MODE}${C_TEXT_MUTED} | User: ${C_TEXT}${CYBER_USER} (UID ${CYBER_UID})${C_RESET}"
        echo -e "${C_TEXT_MUTED}Type ${C_PRIMARY}'exit'${C_TEXT_MUTED} to return to CyberVPS.\n${C_RESET}"
        CYBERVPS_HOST_SHELL=1 "${SHELL:-/bin/bash}" -l
        return 0
    fi

    local name="${1:-main}"
    cyber_guest_is_ready "$name" || {
        cyber_guest_install_rootfs "$name" || return $?
    }

    local gdir
    gdir="$(cyber_guest_dir "$name")"
    local proot_bin
    proot_bin="$(cyber_proot_find_bin)" || {
        log_error "PRoot binary not available."
        return 3
    }

    local binds=(
        -b /proc:/proc
        -b /sys:/sys
        -b /dev:/dev
        -b /dev/pts:/dev/pts
        -b /dev/shm:/dev/shm
        -b /etc/resolv.conf:/etc/resolv.conf
        -b "$HOME":/root/host
    )

    echo -e "\n${C_PRIMARY}${C_BOLD}CyberVPS Virtual Root${C_RESET}"
    echo -e "${C_TEXT_MUTED}Backend: ${C_TEXT}PRoot${C_TEXT_MUTED} | Guest: ${C_TEXT}Debian${C_TEXT_MUTED} | Host Home: ${C_TEXT}/root/host${C_RESET}"
    echo -e "${C_TEXT_MUTED}Type ${C_PRIMARY}'cybervps host'${C_TEXT_MUTED} or ${C_PRIMARY}'exit'${C_TEXT_MUTED} to return to host.\n${C_RESET}"

    local shell_bin="/bin/bash"
    [ -x "$gdir/bin/bash" ] || shell_bin="/bin/sh"

    PROOT_NO_SECCOMP=1 "$proot_bin" \
        -0 \
        -r "$gdir" \
        "${binds[@]}" \
        -w /root \
        /usr/bin/env -i \
            HOME=/root \
            USER=root \
            LOGNAME=root \
            TERM="${TERM:-xterm-256color}" \
            PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
            "$shell_bin" --login
}

cyber_guest_apt() {
    local name="main"
    if [ "$#" -gt 0 ] && [ "$1" != "--" ] && cyber_guest_is_ready "$1"; then
        name="$1"
        shift
    fi
    [ "$#" -gt 0 ] && [ "$1" = "--" ] && shift
    cyber_guest_exec "$name" -- apt-get "$@"
}
