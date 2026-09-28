#!/usr/bin/env bash
# lib/auto.sh — CyberVPS Ultra Auto Zero-Touch Engine
# Automatically scans the host environment, resolves optimal execution mode (Native Root vs PRoot Virtual Root vs Userspace),
# and provisions complete hosting and development environments with zero technical questions.

[ -n "${_CYBERVPS_AUTO_SH_LOADED:-}" ] && return 0
_CYBERVPS_AUTO_SH_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=lib/privilege.sh
source "$LIB_DIR/privilege.sh"
# shellcheck source=lib/resources.sh
source "$LIB_DIR/resources.sh"
# shellcheck source=lib/capabilities.sh
source "$LIB_DIR/capabilities.sh"
# shellcheck source=lib/network.sh
source "$LIB_DIR/network.sh"
# shellcheck source=lib/ports.sh
source "$LIB_DIR/ports.sh"
# shellcheck source=lib/proot.sh
source "$LIB_DIR/proot.sh"
# shellcheck source=lib/install.sh
source "$LIB_DIR/install.sh"
# shellcheck source=lib/services.sh
source "$LIB_DIR/services.sh"

# Global state for auto-detection
CYBER_AUTO_MODE=""
CYBER_AUTO_REASON=""

cyber_auto_scan() {
    detect_environment
    detect_network >/dev/null 2>&1 || true

    # Determine optimal execution mode
    if [ "$CYBER_CAN_ADMIN" = true ]; then
        CYBER_AUTO_MODE="NATIVE_ROOT"
        if [ "$CYBER_IS_CONTAINER" = true ]; then
            CYBER_AUTO_REASON="Container root / Sudo access available ($CYBER_CONTAINER_TYPE)"
        else
            CYBER_AUTO_REASON="Full native host root / administrative access"
        fi
    elif [ "$CYBER_PLATFORM" = "Windows" ]; then
        if command -v wsl.exe >/dev/null 2>&1; then
            CYBER_AUTO_MODE="WSL_BRIDGE"
            CYBER_AUTO_REASON="Windows with WSL virtualization available"
        else
            CYBER_AUTO_MODE="WINDOWS_NATIVE"
            CYBER_AUTO_REASON="Windows standalone userspace"
        fi
    else
        # Linux / Unix unprivileged
        # Check if native user namespaces work
        if command -v unshare >/dev/null 2>&1 && unshare -U -r true 2>/dev/null; then
            CYBER_AUTO_MODE="CYBERROOT_USERNS"
            CYBER_AUTO_REASON="Unprivileged Linux user with user namespaces enabled"
        else
            CYBER_AUTO_MODE="PROOT_GUEST"
            CYBER_AUTO_REASON="Unprivileged Linux sandbox / container without user namespace creation; PRoot virtual root recommended"
        fi
    fi
}

cyber_auto_print_profile() {
    cyber_auto_scan
    echo -e "${C_BCYAN}======================================================${C_RESET}"
    echo -e "${C_BWHITE}       CyberVPS Ultra Auto — System Discovery         ${C_RESET}"
    echo -e "${C_BCYAN}======================================================${C_RESET}"
    printf "  %-18s : %s\n" "Host / OS" "$CYBER_DISTRO_PRETTY ($CYBER_ARCH)"
    printf "  %-18s : %s\n" "Privilege Level" "$CYBER_PRIVILEGE_MODE (uid=$CYBER_UID)"
    printf "  %-18s : %s\n" "Virtualization" "$CYBER_CONTAINER_TYPE (Provider: $CYBER_PROVIDER_HINT)"
    printf "  %-18s : %s effective vCPU / %sMB effective RAM\n" "Compute Limits" "$CYBER_NPROC" "$CYBER_RAM_TOTAL_MB"
    printf "  %-18s : %sMB free\n" "Disk Space" "$CYBER_DISK_FREE_MB"
    printf "  %-18s : %s\n" "Recommended Mode" "$CYBER_AUTO_MODE"
    printf "  %-18s : %s\n" "Reason" "$CYBER_AUTO_REASON"
    echo -e "${C_BCYAN}------------------------------------------------------${C_RESET}"
}

# Provision packages according to level
# Levels: 1 (Core), 2 (Hosting), 3 (Developer), 4 (Ultra Full)
cyber_auto_install() {
    local level="${1:-4}"
    cyber_auto_scan

    echo -e "\n${C_BGREEN}=== Initiating CyberVPS Ultra Provisioning (Level $level) ===${C_RESET}"
    echo -e "Selected Mode: ${C_BCYAN}$CYBER_AUTO_MODE${C_RESET} ($CYBER_AUTO_REASON)\n"

    # Initialize ports config
    init_ports_config

    case "$CYBER_AUTO_MODE" in
        NATIVE_ROOT)
            cyber_auto_install_native_root "$level"
            ;;
        PROOT_GUEST)
            cyber_auto_install_proot_guest "$level"
            ;;
        CYBERROOT_USERNS)
            # If native cyberroot CLI is installed use it, otherwise fallback to PRoot guest
            if command -v cyberroot >/dev/null 2>&1; then
                cyber_auto_install_cyberroot "$level"
            else
                cyber_auto_install_proot_guest "$level"
            fi
            ;;
        WSL_BRIDGE|WINDOWS_NATIVE)
            cyber_auto_install_windows "$level"
            ;;
        *)
            cyber_auto_install_userspace "$level"
            ;;
    esac

    # Ensure CLI helpers and shell integration
    cyber_auto_setup_shell_integration
    echo -e "\n${C_BGREEN}✔ CyberVPS Ultra Auto Provisioning Complete!${C_RESET}"
}

cyber_auto_install_native_root() {
    local level="$1"
    log_info "Installing packages natively using system package manager ($CYBER_PACKAGE_MANAGER)..."

    local pkgs_core="curl wget git jq tmux htop nano tar xz-utils ca-certificates openssh-client"
    local pkgs_hosting="nginx python3 python3-pip python3-venv sqlite3 redis-server"
    local pkgs_php="php-cli php-fpm php-curl php-mbstring php-xml php-zip php-sqlite3"
    local pkgs_dev="build-essential gcc g++ clang make cmake pkg-config libssl-dev zlib1g-dev"

    if [ "$CYBER_PACKAGE_MANAGER" = "apt-get" ] || [ "$CYBER_PACKAGE_MANAGER" = "apt" ]; then
        export DEBIAN_FRONTEND=noninteractive
        cyber_run_privileged apt-get update -y || true

        local to_install="$pkgs_core"
        if [ "$level" -ge 2 ]; then
            to_install="$to_install $pkgs_hosting $pkgs_php"
        fi
        if [ "$level" -ge 3 ]; then
            to_install="$to_install $pkgs_dev"
        fi

        log_info "Executing: apt-get install -y $to_install"
        # shellcheck disable=SC2086
        cyber_run_privileged apt-get install -y --no-install-recommends $to_install || {
            log_warn "Some system packages failed to install; proceeding with installed subsets."
        }

        # Node.js and PM2 for Level >= 2
        if [ "$level" -ge 2 ]; then
            if ! command -v node >/dev/null 2>&1; then
                log_info "Installing Node.js LTS..."
                cyber_run_privileged apt-get install -y nodejs npm || true
            fi
            if command -v npm >/dev/null 2>&1; then
                log_info "Installing PM2 and pnpm..."
                npm install -g pm2 pnpm 2>/dev/null || npm install -g --prefix "$HOME/.local" pm2 pnpm 2>/dev/null || true
            fi
        fi

        # Rust & Go for Level >= 3
        if [ "$level" -ge 3 ]; then
            if ! command -v go >/dev/null 2>&1; then
                cyber_run_privileged apt-get install -y golang || true
            fi
            if ! command -v rustc >/dev/null 2>&1; then
                cyber_run_privileged apt-get install -y rustc cargo || true
            fi
        fi
    elif [ "$CYBER_PACKAGE_MANAGER" = "dnf" ] || [ "$CYBER_PACKAGE_MANAGER" = "yum" ]; then
        local mgr="$CYBER_PACKAGE_MANAGER"
        cyber_run_privileged "$mgr" -y install curl wget git jq tmux htop nano tar xz ca-certificates || true
        if [ "$level" -ge 2 ]; then
            cyber_run_privileged "$mgr" -y install nginx python3 python3-pip sqlite redis nodejs npm php-cli php-fpm || true
        fi
        if [ "$level" -ge 3 ]; then
            cyber_run_privileged "$mgr" -y install gcc gcc-c++ clang make cmake golang rust cargo || true
        fi
    elif [ "$CYBER_PACKAGE_MANAGER" = "apk" ]; then
        cyber_run_privileged apk update || true
        cyber_run_privileged apk add curl wget git jq tmux htop nano tar xz ca-certificates bash || true
        if [ "$level" -ge 2 ]; then
            cyber_run_privileged apk add nginx python3 py3-pip sqlite redis nodejs npm php-fpm php-cli || true
        fi
        if [ "$level" -ge 3 ]; then
            cyber_run_privileged apk add build-base clang cmake go rust cargo || true
        fi
    fi

    # Configure Web server default site on non-privileged or configured port
    if [ "$level" -ge 2 ] && command -v nginx >/dev/null 2>&1; then
        cyber_auto_configure_nginx
    fi

    # Level 4: Cloudflare Tunnel & Webterm
    if [ "$level" -ge 4 ]; then
        cyber_auto_install_extras
    fi
}

cyber_auto_install_proot_guest() {
    local level="$1"
    log_info "Setting up PRoot virtual root environment (guest: 'main')..."

    cyber_proot_ensure_bin || {
        log_error "Could not setup PRoot binary. Falling back to portable userspace installation."
        cyber_auto_install_userspace "$level"
        return $?
    }

    if ! cyber_guest_is_ready "main"; then
        log_info "Downloading and provisioning base virtual root filesystem..."
        cyber_guest_install_rootfs "main" "debian" || {
            log_error "Could not extract rootfs. Falling back to portable userspace installation."
            cyber_auto_install_userspace "$level"
            return $?
        }
    fi

    log_info "Configuring packages inside virtual root (Level $level)..."
    local pkgs_core="curl wget git jq tmux htop nano tar xz-utils ca-certificates openssh-client"
    local pkgs_hosting="nginx python3 python3-pip python3-venv sqlite3 redis-server php-cli php-fpm php-curl php-mbstring php-xml php-zip php-sqlite3 nodejs npm"
    local pkgs_dev="build-essential gcc g++ clang make cmake pkg-config libssl-dev zlib1g-dev golang rustc cargo"

    local to_install="$pkgs_core"
    if [ "$level" -ge 2 ]; then
        to_install="$to_install $pkgs_hosting"
    fi
    if [ "$level" -ge 3 ]; then
        to_install="$to_install $pkgs_dev"
    fi

    log_info "Installing via guest apt-get: $to_install"
    # shellcheck disable=SC2086
    cyber_guest_exec main -- apt-get install -y --no-install-recommends $to_install || {
        log_warn "Some guest packages failed to install; guest remains operational with available packages."
    }

    # Node tooling inside guest
    if [ "$level" -ge 2 ]; then
        cyber_guest_exec main -- npm install -g pm2 pnpm 2>/dev/null || true
    fi

    # Level 4 extras on host
    if [ "$level" -ge 4 ]; then
        cyber_auto_install_extras
    fi
}

cyber_auto_install_cyberroot() {
    local level="$1"
    log_info "Configuring CyberRoot native guest..."
    cyberroot_cli create debian --name main || {
        log_warn "Native cyberroot guest creation failed; falling back to PRoot."
        cyber_auto_install_proot_guest "$level"
        return $?
    }
}

cyber_auto_install_userspace() {
    local level="$1"
    log_info "Provisioning portable userspace runtimes..."
    install_resolve_mode "rootless"
    ensure_user_paths

    # Install Python & SQLite via micromamba if needed
    if ! have_command python3; then
        install_micromamba || true
    fi

    if [ "$level" -ge 2 ]; then
        install_component node || true
        install_component pm2 || true
        install_component pnpm || true
    fi

    if [ "$level" -ge 3 ]; then
        install_component go || true
        install_component rust || true
    fi

    if [ "$level" -ge 4 ]; then
        cyber_auto_install_extras
    fi
}

cyber_auto_install_windows() {
    local level="$1"
    log_info "Configuring Windows environment..."
    if [ "$CYBER_AUTO_MODE" = "WSL_BRIDGE" ]; then
        log_info "Bridging to WSL default distribution..."
        wsl.exe -e bash -c "curl -fsSL https://raw.githubusercontent.com/cyberdrivepro/cyberbackup/main/fresh-install.sh | bash -s -- --profile hosting" 2>/dev/null || true
    else
        log_info "Installing Windows portable runtimes..."
        if command -v winget.exe >/dev/null 2>&1; then
            winget.exe install --id Git.Git -e --source winget 2>/dev/null || true
            [ "$level" -ge 2 ] && winget.exe install --id Python.Python.3.11 -e --source winget 2>/dev/null || true
            [ "$level" -ge 2 ] && winget.exe install --id OpenJS.NodeJS.LTS -e --source winget 2>/dev/null || true
        fi
    fi
}

cyber_auto_configure_nginx() {
    local web_port
    web_port="$(get_port WEB_PORT 8080)"
    local www_root="${HOME}/www"
    ensure_directory "$www_root" 0755

    cat > "$www_root/index.html" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>CyberVPS Ultra — Operational</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f172a; color: #f8fafc; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
        .card { background: #1e293b; padding: 2.5rem; border-radius: 12px; box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.5); max-width: 500px; text-align: center; border: 1px solid #334155; }
        h1 { color: #38bdf8; margin-top: 0; font-size: 1.8rem; }
        p { color: #94a3b8; line-height: 1.6; }
        .status { display: inline-block; padding: 0.35rem 0.85rem; border-radius: 9999px; font-size: 0.85rem; font-weight: 600; background: #065f46; color: #34d399; margin-top: 1rem; }
    </style>
</head>
<body>
    <div class="card">
        <h1>⚡ CyberVPS Ultra</h1>
        <p>Universal Hosting & Application Platform is operational.</p>
        <div class="status">● System Running</div>
    </div>
</body>
</html>
EOF
}

cyber_auto_install_extras() {
    log_info "Installing Cloudflare Tunnel (cloudflared)..."
    install_cloudflared >/dev/null 2>&1 || true

    log_info "Configuring Web Terminal..."
    webterm_ensure_auth >/dev/null 2>&1 || true
}

cyber_auto_setup_shell_integration() {
    local rc="$HOME/.bashrc"
    [ -f "$rc" ] || touch "$rc"

    # Add CyberVPS CLI helpers to PATH and aliases
    local mark="# CyberVPS Ultra Integration"
    if ! grep -q "$mark" "$rc" 2>/dev/null; then
        cat >> "$rc" << 'EOF'

# CyberVPS Ultra Integration
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"
alias cybervps="$HOME/cyberbackup/cybervps.sh"
alias croot="cybervps shell"
alias cstatus="cybervps status"
alias chost="CYBERVPS_HOST_SHELL=1 bash -l"

# Auto-enter Virtual Root for interactive SSH logins (disabled via CYBERVPS_HOST_SHELL=1)
if [ -z "${CYBERVPS_HOST_SHELL:-}" ] && [ -z "${SSH_ORIGINAL_COMMAND:-}" ] && [ -t 0 ] && [[ $- == *i* ]]; then
    if [ -f "$HOME/.local/share/cybervps/guests/main/bin/sh" ] && [ -x "$HOME/.local/bin/proot" ]; then
        if [ "$(id -u)" != "0" ]; then
            exec "$HOME/cyberbackup/cybervps.sh" shell
        fi
    fi
fi
EOF
        log_ok "Shell integration installed in $rc"
    fi
}
