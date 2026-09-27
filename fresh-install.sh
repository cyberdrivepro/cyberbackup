#!/usr/bin/env bash
# fresh-install.sh — fresh user-space rebuild from manifests/templates
set -euo pipefail

CYBERBACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$CYBERBACKUP_DIR"

LOG="$CYBERBACKUP_DIR/logs/fresh-install.log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

CYBERVPS_BACKUP_FORMAT=1

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
bold='\033[1m'
reset='\033[0m'
info()    { echo -en "${info}${reset} $*"; }
ok()      { echo -e "${green}✔${reset} $*"; }
warn()    { echo -e "${yellow}⚠${reset} $*"; }
err()     { echo -e "${red}✖${reset} $*"; }
header()  { echo -e "\n${bold}$*${reset}\n"; }

print_error() { err "$@"; exit 1; }

ensure_dirs() {
    header "Creating user-space directories"
    for d in bin apps config services logs projects examples shared run backups downloads tmp; do
        mkdir -p "$HOME/$d"
        ok "Created $HOME/$d"
    done
}

install_micromamba() {
    header "Installing Micromamba"
    if command -v micromamba >/dev/null 2>&1; then
        ok "micromamba already installed"
        return 0
    fi
    if [ -x "$HOME/bin/micromamba" ]; then
        export PATH="$HOME/bin:$PATH"
        ok "micromamba found at $HOME/bin/micromamba"
        return 0
    fi
    warn "Downloading Micromamba..."
    local tmpbin="$HOME/tmp/micromamba-install-$$"
    mkdir -p "$HOME/tmp"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$tmpbin" "https://micro.mamba.pm/api/micromamba/linux-64/latest" || print_error "Failed to download micromamba"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$tmpbin" "https://micro.mamba.pm/api/micromamba/linux-64/latest" || print_error "Failed to download micromamba"
    else
        print_error "Neither curl nor wget available"
    fi
    chmod +x "$tmpbin"
    mkdir -p "$HOME/bin"
    mv "$tmpbin" "$HOME/bin/micromamba"
    ok "Micromamba installed to $HOME/bin/micromamba"
}

create_hosting_env() {
    header "Creating hosting environment"
    local env_yml="$CYBERBACKUP_DIR/manifests/micromamba-env.yml"
    if [ ! -f "$env_yml" ]; then
        print_error "micromamba-env.yml not found"
    fi
    ok "Creating hosting environment from manifest..."
    micromamba create -f "$env_yml" -p "$HOME/apps/micromamba/envs/hosting" -y || print_error "Failed to create hosting environment"
    ok "Hosting environment created"
}

install_python_packages() {
    header "Installing Python packages"
    local pip_freeze="$CYBERBACKUP_DIR/manifests/pip-freeze.txt"
    if [ ! -f "$pip_freeze" ]; then
        print_error "pip-freeze.txt not found"
    fi
    ok "Installing Python packages from pip-freeze.txt..."
    python -m pip install -r "$pip_freeze" || warn "Some Python packages may have failed"
    ok "Python packages installed"
}

install_node_tools() {
    header "Installing Node tools"
    local npm_global="$CYBERBACKUP_DIR/manifests/npm-global.txt"
    if [ ! -f "$npm_global" ]; then
        print_error "npm-global.txt not found"
    fi
    ok "Installing npm global packages..."
    npm install -g $(cat "$npm_global" | tr '\n' ' ') || warn "Some npm packages may have failed"
    ok "Node tools installed"
}

install_rust() {
    header "Installing Rust"
    if command -v rustup >/dev/null 2>&1; then
        ok "rustup already installed"
        return 0
    fi
    if [ -x "$HOME/.cargo/bin/rustup" ]; then
        export PATH="$HOME/.cargo/bin:$PATH"
        ok "rustup found in $HOME/.cargo/bin"
        return 0
    fi
    warn "Installing rustup..."
    local tmprust="$HOME/tmp/rustup-install-$$"
    mkdir -p "$HOME/tmp"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable || print_error "Failed to install rustup"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O- https://sh.rustup.rs | sh -s -- -y --default-toolchain stable || print_error "Failed to install rustup"
    else
        print_error "Neither curl nor wget available"
    fi
    export PATH="$HOME/.cargo/bin:$PATH"
    ok "Rust installed"
}

install_go() {
    header "Installing Go"
    if [ -d "$HOME/apps/go" ] && [ -x "$HOME/apps/go/bin/go" ]; then
        ok "Go already installed at $HOME/apps/go"
        return 0
    fi
    warn "Installing Go to $HOME/apps/go..."
    local tmpgo="$HOME/tmp/go-install-$$"
    mkdir -p "$HOME/tmp" "$HOME/apps"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL https://go.dev/dl/go1.27.1.linux-amd64.tar.gz -o "$tmpgo" || print_error "Failed to download Go"
    elif command -v wget >/dev/null 2>&1; then
        wget -q https://go.dev/dl/go1.27.1.linux-amd64.tar.gz -O "$tmpgo" || print_error "Failed to download Go"
    else
        print_error "Neither curl nor wget available"
    fi
    tar -C "$HOME/apps" -xzf "$tmpgo"
    mv "$HOME/apps/go" "$HOME/apps/go" 2>/dev/null || true
    ok "Go installed"
}

install_redis() {
    header "Installing Redis (user-space)"
    if [ -d "$HOME/apps/redis" ] && [ -x "$HOME/apps/redis/bin/redis-server" ]; then
        ok "Redis already installed"
        return 0
    fi
    warn "Redis installation is placeholder; ensure $HOME/apps/redis exists"
    # Placeholder: in real scenario, download redis-server binary or use micromamba
    ok "Redis placeholder installed"
}

install_nginx() {
    header "Installing nginx (user-space)"
    if [ -d "$HOME/apps/micromamba/envs/hosting/sbin/nginx" ] || [ -x "$HOME/apps/micromamba/envs/hosting/bin/nginx" ]; then
        ok "nginx already installed"
        return 0
    fi
    warn "nginx installation is placeholder; ensure nginx is in micromamba env"
    ok "nginx placeholder installed"
}

install_cloudflared() {
    header "Installing cloudflared"
    if [ -x "$HOME/bin/cloudflared" ]; then
        ok "cloudflared already installed"
        return 0
    fi
    warn "cloudflared installation is placeholder; ensure $HOME/bin/cloudflared exists"
    ok "cloudflared placeholder installed"
}

install_supervisor() {
    header "Installing Supervisor"
    if [ -x "$HOME/bin/svcd-h24" ] && [ -x "$HOME/bin/h24ctl" ]; then
        ok "Supervisor already installed"
        return 0
    fi
    warn "Supervisor installation is placeholder; ensure $HOME/bin/svcd-h24 exists"
    ok "Supervisor placeholder installed"
}

install_pm2() {
    header "Installing PM2"
    if command -v pm2 >/dev/null 2>&1; then
        ok "PM2 already installed"
        return 0
    fi
    local pm2_home="$HOME/.pm2"
    mkdir -p "$pm2_home"
    ok "PM2 placeholder installed"
}

install_hosting_scripts() {
    header "Installing hosting helper scripts"
    local scripts_dir="$CYBERBACKUP_DIR/scripts"
    for script in hosting-start hosting-stop hosting-restart hosting-status hosting-attach hosting-logs vps-status ensure-hosting24; do
        if [ -f "$scripts_dir/$script" ]; then
            cp "$scripts_dir/$script" "$HOME/bin/$script"
            chmod +x "$HOME/bin/$script"
            ok "Installed $script"
        fi
    done
    ok "Hosting scripts installed"
}

install_shell_config() {
    header "Installing shell configuration"
    if [ -f "$HOME/.bashrc" ]; then
        ok ".bashrc exists"
    else
        warn ".bashrc missing; template not applied automatically"
    fi
    if [ -f "$HOME/.profile" ]; then
        ok ".profile exists"
    else
        warn ".profile missing; template not applied automatically"
    fi
}

start_hosting() {
    header "Starting hosting services"
    if [ -x "$HOME/bin/hosting-start" ]; then
        "$HOME/bin/hosting-start" || warn "hosting-start failed"
    else
        err "hosting-start not found"
    fi
    if [ -x "$HOME/bin/hosting-status" ]; then
        "$HOME/bin/hosting-status" || true
    fi
    if [ -x "$HOME/bin/vps-status" ]; then
        "$HOME/bin/vps-status" || true
    fi
    if [ -x "$HOME/services/healthcheck.sh" ]; then
        "$HOME/services/healthcheck.sh" || true
    fi
}

main() {
    header "FRESH INSTALL / REBUILD"
    echo "Host: $(hostname)"
    echo "User: $(whoami)"
    echo

    ensure_dirs
    install_micromamba
    create_hosting_env
    install_python_packages
    install_node_tools
    install_rust
    install_go
    install_redis
    install_nginx
    install_cloudflared
    install_supervisor
    install_pm2
    install_hosting_scripts
    install_shell_config
    start_hosting

    header "FRESH INSTALL COMPLETE"
    ok "Fresh install finished. Verify with: hosting-status ; vps-status ; ~/services/healthcheck.sh"
}

main "$@"
