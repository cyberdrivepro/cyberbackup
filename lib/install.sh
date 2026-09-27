#!/usr/bin/env bash
# lib/install.sh — Non-root user-space installer engine for CyberVPS
# Strictly rootless. Follows binary priority: host -> user-space -> micromamba -> standalone -> native -> source.

[ -n "${_CYBERVPS_INSTALL_SH_LOADED:-}" ] && return 0
_CYBERVPS_INSTALL_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"

USER_BIN_DIR="${HOME}/bin"
USER_APPS_DIR="${HOME}/apps"
USER_TMP_DIR="${HOME}/tmp"

ensure_user_paths() {
    ensure_directory "$USER_BIN_DIR"
    ensure_directory "$USER_APPS_DIR"
    ensure_directory "$USER_TMP_DIR"
    ensure_directory "${HOME}/config"
    ensure_directory "${HOME}/services"
    ensure_directory "${HOME}/logs"
    ensure_directory "${HOME}/run"
    ensure_directory "${HOME}/backups"
}

# Install or ensure micromamba
install_micromamba() {
    log_header "Checking / Installing Micromamba"

    if have_command micromamba; then
        log_ok "Micromamba already in PATH ($(command -v micromamba))"
        return 0
    fi
    if [ -x "$USER_BIN_DIR/micromamba" ]; then
        export PATH="$USER_BIN_DIR:$PATH"
        log_ok "Micromamba found in $USER_BIN_DIR"
        return 0
    fi

    detect_environment
    if [ -z "${CYBER_MAMBA_ARCH:-}" ]; then
        log_error "Micromamba does not support architecture: $CYBER_ARCH"
        return 1
    fi

    local mamba_url="https://micro.mamba.pm/api/micromamba/${CYBER_MAMBA_ARCH}/latest"
    local dl_tar="$USER_TMP_DIR/micromamba-latest.tar.bz2"
    local extract_dir="$USER_TMP_DIR/micromamba-extract-$$"

    log_info "Downloading Micromamba for ${CYBER_MAMBA_ARCH}..."
    if ! download_file "$mamba_url" "$dl_tar"; then
        log_error "Failed to download Micromamba"
        return 1
    fi

    mkdir -p "$extract_dir"
    tar -xjf "$dl_tar" -C "$extract_dir" bin/micromamba 2>/dev/null || tar -xjf "$dl_tar" -C "$extract_dir"
    if [ -f "$extract_dir/bin/micromamba" ]; then
        mv "$extract_dir/bin/micromamba" "$USER_BIN_DIR/micromamba"
    elif [ -f "$extract_dir/micromamba" ]; then
        mv "$extract_dir/micromamba" "$USER_BIN_DIR/micromamba"
    else
        log_error "Could not find micromamba binary in downloaded archive"
        rm -rf "$extract_dir" "$dl_tar"
        return 1
    fi

    chmod +x "$USER_BIN_DIR/micromamba"
    rm -rf "$extract_dir" "$dl_tar"

    export PATH="$USER_BIN_DIR:$PATH"
    log_ok "Micromamba successfully installed to $USER_BIN_DIR/micromamba"
    return 0
}

# Create or verify hosting environment in Micromamba
setup_hosting_env() {
    local env_name="${CYBERVPS_ENV_NAME:-hosting}"
    local mamba_root="$USER_APPS_DIR/micromamba"
    local env_prefix="$mamba_root/envs/$env_name"

    install_micromamba || return 1

    if [ -d "$env_prefix" ] && [ -x "$env_prefix/bin/python" ]; then
        log_ok "Micromamba environment '$env_name' is already installed at $env_prefix"
        return 0
    fi

    log_header "Creating Micromamba '$env_name' Environment"
    ensure_directory "$mamba_root"

    # Base packages: python 3.12, nodejs, npm, git, sqlite, curl, zstd, openssl
    local base_pkgs="python=3.12 nodejs=22 git sqlite curl zstd openssl pip"

    MAMBA_ROOT_PREFIX="$mamba_root" "$USER_BIN_DIR/micromamba" create -y -n "$env_name" \
        -c conda-forge $base_pkgs

    log_ok "Environment '$env_name' created successfully"
}

# Install Cloudflared
install_cloudflared() {
    log_header "Checking / Installing Cloudflared"

    if have_command cloudflared; then
        log_ok "Cloudflared already available ($(command -v cloudflared))"
        return 0
    fi
    if [ -x "$USER_BIN_DIR/cloudflared" ]; then
        export PATH="$USER_BIN_DIR:$PATH"
        log_ok "Cloudflared found in $USER_BIN_DIR"
        return 0
    fi

    detect_environment
    if [ -z "${CYBER_CLOUDFLARED_ARCH:-}" ]; then
        log_error "Cloudflared not supported on architecture: $CYBER_ARCH"
        return 1
    fi

    local cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CYBER_CLOUDFLARED_ARCH}"
    local dest="$USER_BIN_DIR/cloudflared"

    log_info "Downloading Cloudflared (linux-${CYBER_CLOUDFLARED_ARCH})..."
    if download_file "$cf_url" "$dest"; then
        chmod +x "$dest"
        export PATH="$USER_BIN_DIR:$PATH"
        log_ok "Cloudflared installed to $dest"
        return 0
    else
        log_error "Cloudflared download failed"
        return 1
    fi
}

# Install Go in user space ($HOME/apps/go)
install_go() {
    local target_ver="${1:-1.23.4}"
    log_header "Checking / Installing Go"

    if have_command go; then
        log_ok "Go already in PATH ($(command -v go))"
        return 0
    fi
    if [ -x "$USER_APPS_DIR/go/bin/go" ]; then
        export PATH="$USER_APPS_DIR/go/bin:$PATH"
        log_ok "Go found in $USER_APPS_DIR/go/bin"
        return 0
    fi

    detect_environment
    if [ -z "${CYBER_GO_ARCH:-}" ]; then
        log_error "Go not supported on architecture: $CYBER_ARCH"
        return 1
    fi

    local tarball="go${target_ver}.${CYBER_GO_ARCH}.tar.gz"
    local go_url="https://go.dev/dl/${tarball}"
    local dl_dest="$USER_TMP_DIR/$tarball"

    log_info "Downloading Go ${target_ver} for ${CYBER_GO_ARCH}..."
    if ! download_file "$go_url" "$dl_dest"; then
        log_error "Failed to download Go"
        return 1
    fi

    ensure_directory "$USER_APPS_DIR"
    rm -rf "$USER_APPS_DIR/go"
    tar -xzf "$dl_dest" -C "$USER_APPS_DIR"
    rm -f "$dl_dest"

    export PATH="$USER_APPS_DIR/go/bin:$PATH"
    log_ok "Go installed to $USER_APPS_DIR/go"
    return 0
}

# Install Rust via user-space rustup
install_rust() {
    log_header "Checking / Installing Rust"

    if have_command rustc && have_command cargo; then
        log_ok "Rust and Cargo already available ($(command -v rustc))"
        return 0
    fi
    if [ -x "${HOME}/.cargo/bin/rustc" ]; then
        export PATH="${HOME}/.cargo/bin:$PATH"
        log_ok "Rust found in ~/.cargo/bin"
        return 0
    fi

    log_info "Installing Rust via rootless rustup..."
    local rustup_init="$USER_TMP_DIR/rustup-init.sh"
    if download_file "https://sh.rustup.rs" "$rustup_init"; then
        chmod +x "$rustup_init"
        RUSTUP_HOME="${HOME}/.rustup" CARGO_HOME="${HOME}/.cargo" \
            bash "$rustup_init" -y --no-modify-path --profile minimal
        rm -f "$rustup_init"
        export PATH="${HOME}/.cargo/bin:$PATH"
        log_ok "Rust installed successfully"
        return 0
    else
        log_error "Failed to download rustup installer"
        return 1
    fi
}

# Install Node global package in user space
install_node_global_tool() {
    local tool="$1"
    if have_command "$tool"; then
        log_ok "Node tool '$tool' already available"
        return 0
    fi
    if have_command npm; then
        log_info "Installing Node tool '$tool' via npm global..."
        npm install -g "$tool" --prefix "${HOME}/.npm-global" 2>/dev/null || npm install -g "$tool"
        export PATH="${HOME}/.npm-global/bin:$PATH"
        log_ok "Installed '$tool'"
        return 0
    fi
    log_warn "npm not available; cannot install '$tool'"
    return 1
}

# Install curated stack profiles
install_profile() {
    local profile="${1:-hosting}"
    local inst_dir="$CYBERVPS_ROOT/installers"

    ensure_user_paths
    ensure_cybervps_profile

    case "$profile" in
        minimal)
            log_header "Installing Profile: Minimal"
            init_ports_config
            ;;
        hosting)
            log_header "Installing Profile: Hosting"
            [ -f "$inst_dir/node.sh" ] && bash "$inst_dir/node.sh"
            [ -f "$inst_dir/redis.sh" ] && bash "$inst_dir/redis.sh"
            [ -f "$inst_dir/nginx.sh" ] && bash "$inst_dir/nginx.sh"
            [ -f "$inst_dir/cloudflared.sh" ] && bash "$inst_dir/cloudflared.sh"
            ;;
        developer)
            log_header "Installing Profile: Developer"
            [ -f "$inst_dir/micromamba.sh" ] && bash "$inst_dir/micromamba.sh"
            [ -f "$inst_dir/python.sh" ] && bash "$inst_dir/python.sh"
            [ -f "$inst_dir/node.sh" ] && bash "$inst_dir/node.sh"
            [ -f "$inst_dir/go.sh" ] && bash "$inst_dir/go.sh"
            [ -f "$inst_dir/rust.sh" ] && bash "$inst_dir/rust.sh"
            ;;
        full)
            log_header "Installing Profile: Full Stack"
            [ -f "$inst_dir/micromamba.sh" ] && bash "$inst_dir/micromamba.sh"
            [ -f "$inst_dir/python.sh" ] && bash "$inst_dir/python.sh"
            [ -f "$inst_dir/node.sh" ] && bash "$inst_dir/node.sh"
            [ -f "$inst_dir/redis.sh" ] && bash "$inst_dir/redis.sh"
            [ -f "$inst_dir/nginx.sh" ] && bash "$inst_dir/nginx.sh"
            [ -f "$inst_dir/cloudflared.sh" ] && bash "$inst_dir/cloudflared.sh"
            [ -f "$inst_dir/go.sh" ] && bash "$inst_dir/go.sh"
            [ -f "$inst_dir/rust.sh" ] && bash "$inst_dir/rust.sh"
            ;;
        *)
            log_error "Unknown profile: $profile (valid: minimal, hosting, developer, full)"
            return 1
            ;;
    esac
    log_ok "Profile '$profile' installation completed."
}
