#!/usr/bin/env bash
# Capability-driven installation. System packages and portable state stay separate.
[ -n "${_CYBERVPS_INSTALL_SH_LOADED:-}" ] && return 0
_CYBERVPS_INSTALL_SH_LOADED=1
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=lib/download.sh
source "$LIB_DIR/download.sh"

USER_BIN_DIR="${HOME}/bin"
USER_APPS_DIR="${HOME}/apps"
USER_TMP_DIR="${HOME}/tmp"
INSTALL_COMPONENTS=()
INSTALL_REQUIRED=()
INSTALL_RESULTS=()

install_refresh_path() {
    export PATH="$USER_BIN_DIR:$HOME/.local/bin:$USER_APPS_DIR/node/bin:$USER_APPS_DIR/go/bin:$HOME/.cargo/bin:$HOME/.npm-global/bin:$USER_APPS_DIR/micromamba/envs/${CYBERVPS_ENV_NAME:-hosting}/bin:$USER_APPS_DIR/micromamba/envs/${CYBERVPS_ENV_NAME:-hosting}/sbin:$PATH"
}

ensure_user_paths() {
    local dir
    for dir in "$USER_BIN_DIR" "$USER_APPS_DIR" "$USER_TMP_DIR" "$HOME/config" "$HOME/services" "$HOME/logs" "$HOME/run" "$HOME/backups"; do
        ensure_directory "$dir" || return 8
    done
    install_refresh_path
}

install_resolve_mode() {
    local requested="${1:-auto}"
    detect_environment
    case "$requested" in
        auto)
            if [ "${CYBER_SYSTEM_PACKAGES:-UNAVAILABLE}" = AVAILABLE ]; then
                if [ "${CYBER_IS_CONTAINER:-false}" = true ]; then requested=hybrid; else requested=root; fi
            else requested=rootless; fi
            ;;
        root|rootless|hybrid) ;;
        *) log_error 'Install mode must be auto, root, rootless or hybrid.'; return 2 ;;
    esac
    if [ "$requested" != rootless ] && [ "${CYBER_SYSTEM_PACKAGES:-UNAVAILABLE}" != AVAILABLE ]; then
        log_error "Mode '$requested' requires an available native package manager and authorized administration."
        return 3
    fi
    CYBERVPS_INSTALL_MODE="$requested"
    export CYBERVPS_INSTALL_MODE
}

install_mode_has_system_packages() {
    local mode="${CYBERVPS_INSTALL_MODE:-${INSTALL_MODE:-rootless}}"
    case "$mode" in
        root|hybrid)
            [ "${CYBER_SYSTEM_PACKAGES:-UNAVAILABLE}" = AVAILABLE ] && cyber_can_admin
            ;;
        *) return 1 ;;
    esac
}

install_profile_components() {
    local profile="${1,,}" component
    INSTALL_COMPONENTS=(core)
    INSTALL_REQUIRED=(core)
    case "$profile" in
        minimal) ;;
        hosting) INSTALL_COMPONENTS+=(python node sqlite pm2 pnpm nginx cloudflared); INSTALL_REQUIRED+=(python node sqlite) ;;
        developer) INSTALL_COMPONENTS+=(python node sqlite build go rust pm2 pnpm); INSTALL_REQUIRED+=(python node sqlite build go rust) ;;
        full) INSTALL_COMPONENTS+=(python node sqlite build go rust pm2 pnpm nginx redis cloudflared ttyd); INSTALL_REQUIRED+=(python node sqlite) ;;
        desktop) INSTALL_COMPONENTS+=(desktop); INSTALL_REQUIRED+=(desktop) ;;
        cyberroot) INSTALL_COMPONENTS+=(cyberroot); INSTALL_REQUIRED+=(cyberroot) ;;
        cybervm) INSTALL_COMPONENTS+=(cybervm); INSTALL_REQUIRED+=(cybervm) ;;
        agent_only|agent-only) INSTALL_COMPONENTS+=(agent); INSTALL_REQUIRED+=(agent) ;;
        custom)
            [ -n "${CYBERVPS_INSTALL_COMPONENTS:-}" ] || { log_error 'Custom profile requires --components (comma-separated).'; return 2; }
            local -a selected=()
            IFS=',' read -r -a selected <<< "$CYBERVPS_INSTALL_COMPONENTS"
            for component in "${selected[@]}"; do
                case "$component" in core) continue ;; python|node|sqlite|build|go|rust|pm2|pnpm|nginx|redis|cloudflared|ttyd|micromamba|desktop|cyberroot|cybervm|agent) ;;
                    *) log_error "Unknown install component: $component"; return 2 ;;
                esac
                INSTALL_COMPONENTS+=("$component")
                INSTALL_REQUIRED+=("$component")
            done
            ;;
        *) log_error "Unknown profile: $profile"; return 2 ;;
    esac
}

install_component_required() {
    local value
    for value in "${INSTALL_REQUIRED[@]}"; do [ "$value" != "$1" ] || return 0; done
    return 1
}

install_component_ready() {
    install_refresh_path
    case "$1" in
        core)
            have_command git && have_command tar && have_command gzip &&
                { have_command curl || have_command wget; } &&
                { have_command sha256sum || have_command shasum || have_command openssl; } &&
                { have_command tmux || have_command screen || have_command nohup; }
            ;;
        python) have_command python3 && python3 -c 'import sys,venv; sys.exit(sys.version_info < (3,10))' >/dev/null 2>&1 ;;
        node) have_command node && have_command npm && node -e 'process.exit(Number(process.versions.node.split(".")[0]) < 20)' >/dev/null 2>&1 ;;
        sqlite) have_command sqlite3 && sqlite3 --version >/dev/null 2>&1 ;;
        build) have_command cc && have_command c++ && have_command make && have_command cmake && have_command pkg-config ;;
        go) have_command go && go version >/dev/null 2>&1 ;;
        rust) have_command rustc && have_command cargo && rustc --version >/dev/null 2>&1 && cargo --version >/dev/null 2>&1 ;;
        redis) have_command redis-server && redis-server --version >/dev/null 2>&1 ;;
        nginx) have_command nginx && nginx -v >/dev/null 2>&1 ;;
        micromamba) have_command micromamba && micromamba --version >/dev/null 2>&1 ;;
        desktop) have_command startxfce4 && have_command xrdp ;;
        cybervm) have_command qemu-img && { have_command qemu-system-x86_64 || have_command qemu-system-aarch64; } ;;
        cyberroot) have_command cyberroot && cyberroot --version >/dev/null 2>&1 ;;
        agent) have_command cyberagent && cyberagent --version >/dev/null 2>&1 ;;
        pm2|pnpm|cloudflared|ttyd) have_command "$1" ;;
        *) return 2 ;;
    esac
}

# Package names are selected by the canonical distro detector, never by apt presence alone.
install_package_names() {
    local manager="$1" component="$2"
    INSTALL_PACKAGES=()
    case "$manager:$component" in
        apt-get:core) INSTALL_PACKAGES=(ca-certificates curl wget git jq unzip zip tar gzip xz-utils bzip2 tmux sqlite3 openssh-client) ;;
        dnf:core|yum:core) INSTALL_PACKAGES=(ca-certificates curl wget git jq unzip zip tar gzip xz bzip2 tmux sqlite openssh-clients) ;;
        apk:core) INSTALL_PACKAGES=(ca-certificates curl wget git jq unzip zip tar gzip xz bzip2 tmux sqlite openssh-client) ;;
        pacman:core) INSTALL_PACKAGES=(ca-certificates curl wget git jq unzip zip tar gzip xz bzip2 tmux sqlite openssh) ;;
        zypper:core) INSTALL_PACKAGES=(ca-certificates curl wget git jq unzip zip tar gzip xz bzip2 tmux sqlite3 openssh) ;;
        apt-get:python) INSTALL_PACKAGES=(python3 python3-venv python3-pip) ;;
        apk:python) INSTALL_PACKAGES=(python3 py3-pip) ;;
        pacman:python) INSTALL_PACKAGES=(python python-pip) ;;
        dnf:python|yum:python|zypper:python) INSTALL_PACKAGES=(python3 python3-pip) ;;
        *:node) INSTALL_PACKAGES=(nodejs npm) ;;
        apt-get:sqlite|zypper:sqlite) INSTALL_PACKAGES=(sqlite3) ;;
        *:sqlite) INSTALL_PACKAGES=(sqlite) ;;
        apt-get:build) INSTALL_PACKAGES=(build-essential cmake make pkg-config gdb) ;;
        apk:build) INSTALL_PACKAGES=(build-base cmake make pkgconf gdb) ;;
        pacman:build) INSTALL_PACKAGES=(base-devel cmake make pkgconf gdb) ;;
        dnf:build|yum:build|zypper:build) INSTALL_PACKAGES=(gcc gcc-c++ cmake make pkg-config gdb) ;;
        apt-get:go) INSTALL_PACKAGES=(golang-go) ;;
        *:go) INSTALL_PACKAGES=(go) ;;
        apt-get:rust) INSTALL_PACKAGES=(rustc cargo) ;;
        *:rust) INSTALL_PACKAGES=(rust cargo) ;;
        apt-get:desktop) INSTALL_PACKAGES=(xfce4 xrdp) ;;
        apt-get:nginx|dnf:nginx|yum:nginx|apk:nginx|pacman:nginx|zypper:nginx|*:nginx) INSTALL_PACKAGES=(nginx) ;;
        apt-get:redis) INSTALL_PACKAGES=(redis-server redis-tools) ;;
        dnf:redis|yum:redis|zypper:redis|apk:redis|pacman:redis|*:redis) INSTALL_PACKAGES=(redis) ;;
        *) return 3 ;;
    esac
}

install_system_component() {
    local component="$1" manager="${CYBER_PACKAGE_MANAGER:-}"
    install_mode_has_system_packages || return 3
    if [ "$component" = cybervm ]; then
        case "$manager" in
            apt-get) INSTALL_PACKAGES=(qemu-system-x86 qemu-system-arm qemu-utils) ;;
            dnf|yum) INSTALL_PACKAGES=(qemu-system-x86 qemu-img) ;;
            apk) INSTALL_PACKAGES=(qemu-system-x86_64 qemu-img) ;;
            pacman) INSTALL_PACKAGES=(qemu-system-x86 qemu-img) ;;
            zypper) INSTALL_PACKAGES=(qemu-x86 qemu-tools) ;;
            *) return 3 ;;
        esac
    else install_package_names "$manager" "$component" || return $?; fi
    log_info "Installing $component using distro manager $manager (${INSTALL_PACKAGES[*]})."
    if [ "$manager" = apt-get ] && [ "${CYBERVPS_APT_UPDATED:-0}" = 0 ]; then
        cyber_run_privileged env DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update || return 8
        CYBERVPS_APT_UPDATED=1
    fi
    case "$manager" in
        apt-get) cyber_run_privileged env DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=2 -y --no-install-recommends install "${INSTALL_PACKAGES[@]}" ;;
        dnf|yum) cyber_run_privileged "$manager" -y install "${INSTALL_PACKAGES[@]}" ;;
        apk) cyber_run_privileged apk add --no-cache "${INSTALL_PACKAGES[@]}" ;;
        pacman) cyber_run_privileged pacman -S --needed --noconfirm "${INSTALL_PACKAGES[@]}" ;;
        zypper) cyber_run_privileged zypper --non-interactive install --no-recommends "${INSTALL_PACKAGES[@]}" ;;
        *) return 3 ;;
    esac
}

install_verified_binary() {
    local source="$1" dest="$2" expected="$3" temp
    temp="$(mktemp "${dest}.install.XXXXXX")" || return 8
    if ! cyber_download "$source" "$temp" "$expected"; then rm -f -- "$temp" "$temp.source"; return 9; fi
    chmod 0755 "$temp" || { rm -f -- "$temp" "$temp.source"; return 8; }
    if ! "$temp" --version >/dev/null 2>&1; then
        log_error "Downloaded binary cannot execute on this platform: $(basename "$dest")"
        rm -f -- "$temp" "$temp.source"
        return 7
    fi
    mv -f -- "$temp" "$dest" && mv -f -- "$temp.source" "$dest.source"
}

install_micromamba() {
    install_component_ready micromamba && return 0
    [ "${CYBERVPS_MAMBA_UNAVAILABLE:-0}" != 1 ] || return 7
    if [ "${CYBER_LIBC:-unknown}" != glibc ] || [ -z "${CYBER_MAMBA_ARCH:-}" ]; then
        log_warn 'Micromamba portable packages need a supported glibc Linux platform.'
        CYBERVPS_MAMBA_UNAVAILABLE=1
        return 3
    fi
    ensure_user_paths || return $?
    local work expected base archive candidate
    work="$(mktemp -d "$USER_TMP_DIR/micromamba.XXXXXX")" || return 8
    base="https://github.com/mamba-org/micromamba-releases/releases/latest/download/micromamba-${CYBER_MAMBA_ARCH}"
    if ! cyber_download "$base.sha256" "$work/checksum"; then
        log_error 'Official Micromamba checksum unavailable; installation skipped safely.'
        rm -rf -- "$work"; CYBERVPS_MAMBA_UNAVAILABLE=1; return 9
    fi
    read -r expected _ < "$work/checksum" || [ -n "${expected:-}" ]
    if [[ ! "$expected" =~ ^[[:xdigit:]]{64}$ ]]; then rm -rf -- "$work"; CYBERVPS_MAMBA_UNAVAILABLE=1; return 9; fi
    archive="$work/micromamba.tar.bz2"
    candidate="$work/micromamba"
    if cyber_download "https://micro.mamba.pm/api/micromamba/${CYBER_MAMBA_ARCH}/latest" "$archive" &&
        tar -xOjf "$archive" bin/micromamba > "$candidate" &&
        verify_sha256 "$candidate" "${expected,,}" && chmod 0755 "$candidate" && "$candidate" --version >/dev/null 2>&1; then
        if mv -f -- "$candidate" "$USER_BIN_DIR/micromamba"; then
            printf 'source\t%s\nsha256\t%s\nintegrity\tverified\n' "https://micro.mamba.pm/api/micromamba/${CYBER_MAMBA_ARCH}/latest" "$expected" > "$USER_BIN_DIR/micromamba.source"
            rm -rf -- "$work"
            return 0
        fi
    fi
    log_warn 'Micromamba primary endpoint failed; trying the official GitHub binary.'
    if install_verified_binary "$base" "$USER_BIN_DIR/micromamba" "$expected"; then rm -rf -- "$work"; return 0; fi
    rm -rf -- "$work"
    CYBERVPS_MAMBA_UNAVAILABLE=1
    return 7
}

install_mamba_packages() {
    install_micromamba || return $?
    local prefix="$USER_APPS_DIR/micromamba/envs/${CYBERVPS_ENV_NAME:-hosting}" action=create
    [ ! -d "$prefix/conda-meta" ] || action=install
    MAMBA_ROOT_PREFIX="$USER_APPS_DIR/micromamba" micromamba "$action" -y -p "$prefix" -c conda-forge "$@" || return 8
    install_refresh_path
}

# Compatibility API for callers which explicitly want an isolated environment.
setup_hosting_env() { install_mamba_packages 'python>=3.10' 'nodejs>=20' pip sqlite git curl openssl; }

install_node() {
    install_component_ready node && return 0
    [ "${CYBER_LIBC:-unknown}" = glibc ] || { log_error 'Use native Node packages on musl Linux.'; return 3; }
    local arch work record expected archive base
    case "$CYBER_ARCH" in x86_64) arch=x64 ;; aarch64) arch=arm64 ;; *) return 3 ;; esac
    work="$(mktemp -d "$USER_TMP_DIR/node.XXXXXX")" || return 8
    base="https://nodejs.org/dist/${CYBERVPS_NODE_VERSION:-latest-v22.x}"
    if ! cyber_download "$base/SHASUMS256.txt" "$work/checksums"; then rm -rf -- "$work"; return 4; fi
    record="$(awk -v suffix="-linux-$arch.tar.xz" '$2 ~ /^node-v[0-9]+\.[0-9]+\.[0-9]+-linux-/ && substr($2,length($2)-length(suffix)+1)==suffix {print $1 " " $2; exit}' "$work/checksums")"
    read -r expected archive <<< "$record"
    if [[ ! "$expected" =~ ^[[:xdigit:]]{64}$ || ! "$archive" =~ ^node-v[0-9]+\.[0-9]+\.[0-9]+-linux-(x64|arm64)\.tar\.xz$ ]]; then rm -rf -- "$work"; return 9; fi
    if cyber_download "$base/$archive" "$work/archive" "$expected" &&
        tar -xJf "$work/archive" -C "$work" && "$work/${archive%.tar.xz}/bin/node" --version >/dev/null 2>&1; then
        install_replace_directory "$work/${archive%.tar.xz}" "$USER_APPS_DIR/node" || { rm -rf -- "$work"; return 8; }
        mv -f -- "$work/archive.source" "$USER_APPS_DIR/node/download.source"
        rm -rf -- "$work"
        install_component_ready node
        return $?
    fi
    rm -rf -- "$work"
    return 8
}

install_replace_directory() {
    local staged="$1" destination="$2" previous
    previous="${destination}.previous.$$"
    [ ! -e "$previous" ] || return 8
    if [ -e "$destination" ]; then mv -- "$destination" "$previous" || return 8; fi
    if mv -- "$staged" "$destination"; then
        if [ -e "$previous" ]; then rm -rf -- "$previous"; fi
        return 0
    fi
    if [ -e "$previous" ]; then mv -- "$previous" "$destination" || return 8; fi
    return 8
}

install_go() {
    install_component_ready go && return 0
    local work record archive expected
    [ -n "${CYBER_GO_ARCH:-}" ] || return 3
    have_command python3 || { log_error 'Go release metadata verification requires Python 3.'; return 7; }
    work="$(mktemp -d "$USER_TMP_DIR/go.XXXXXX")" || return 8
    if ! cyber_download 'https://go.dev/dl/?mode=json' "$work/releases"; then rm -rf -- "$work"; return 4; fi
    record="$(python3 - "$work/releases" "${CYBER_GO_ARCH#linux-}" <<'PY'
import json, sys
for release in json.load(open(sys.argv[1], encoding="utf-8")):
    if release.get("stable"):
        for asset in release.get("files", []):
            if asset.get("os") == "linux" and asset.get("arch") == sys.argv[2] and asset.get("kind") == "archive":
                print(asset["filename"], asset["sha256"])
                raise SystemExit(0)
raise SystemExit(9)
PY
    )" || { rm -rf -- "$work"; return 9; }
    read -r archive expected <<< "$record"
    if [[ ! "$archive" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?\.linux-[a-z0-9]+\.tar\.gz$ || ! "$expected" =~ ^[[:xdigit:]]{64}$ ]]; then rm -rf -- "$work"; return 9; fi
    if cyber_download "https://go.dev/dl/$archive" "$work/archive" "$expected" "https://dl.google.com/go/$archive" &&
        tar -xzf "$work/archive" -C "$work" && "$work/go/bin/go" version >/dev/null 2>&1; then
        install_replace_directory "$work/go" "$USER_APPS_DIR/go" || { rm -rf -- "$work"; return 8; }
        mv -f -- "$work/archive.source" "$USER_APPS_DIR/go/download.source"
        rm -rf -- "$work"
        install_component_ready go
        return $?
    fi
    rm -rf -- "$work"
    return 8
}

install_rust() {
    install_component_ready rust && return 0
    local triple work base expected rc=0
    case "$CYBER_ARCH" in x86_64|aarch64) triple="$CYBER_ARCH-unknown-linux-gnu" ;; *) return 3 ;; esac
    [ "${CYBER_LIBC:-}" != musl ] || triple="$CYBER_ARCH-unknown-linux-musl"
    work="$(mktemp -d "$USER_TMP_DIR/rustup.XXXXXX")" || return 8
    base="https://static.rust-lang.org/rustup/dist/$triple/rustup-init"
    if ! cyber_download "$base.sha256" "$work/checksum"; then rm -rf -- "$work"; return 4; fi
    read -r expected _ < "$work/checksum" || [ -n "${expected:-}" ]
    if [[ ! "$expected" =~ ^[[:xdigit:]]{64}$ ]] || ! cyber_download "$base" "$work/rustup-init" "$expected"; then rm -rf -- "$work"; return 9; fi
    chmod 0755 "$work/rustup-init" || { rm -rf -- "$work"; return 8; }
    RUSTUP_HOME="$HOME/.rustup" CARGO_HOME="$HOME/.cargo" "$work/rustup-init" -y --default-toolchain stable --profile minimal --no-modify-path || rc=$?
    rm -rf -- "$work"
    [ "$rc" -eq 0 ] && install_component_ready rust
}

install_github_binary() {
    local repo="$1" asset="$2" dest="$3" work record url expected rc=0
    have_command python3 || { log_error 'GitHub release digest verification requires Python 3.'; return 7; }
    work="$(mktemp -d "$USER_TMP_DIR/release.XXXXXX")" || return 8
    if ! cyber_download "https://api.github.com/repos/$repo/releases/latest" "$work/release"; then rm -rf -- "$work"; return 4; fi
    record="$(python3 - "$work/release" "$asset" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assets = data.get("assets", [])
target = sys.argv[2]
url, digest, sums_url = None, None, None
for a in assets:
    if a.get("name") == target:
        url = a.get("browser_download_url")
        if str(a.get("digest", "")).startswith("sha256:"):
            digest = a["digest"][7:]
    name_lower = a.get("name", "").lower()
    if name_lower in ("sha256sums", "sha256sums.txt", "checksums.txt", f"{target.lower()}.sha256"):
        sums_url = a.get("browser_download_url")
if url and digest:
    print(url, digest)
    raise SystemExit(0)
if url and sums_url:
    print(url, "SUMS:" + sums_url)
    raise SystemExit(0)
raise SystemExit(9)
PY
    )" || { log_error "No upstream SHA256 digest for $repo/$asset; refusing unverified installation."; rm -rf -- "$work"; return 9; }
    read -r url expected <<< "$record"
    if [[ "$expected" == SUMS:* ]]; then
        local sums_url="${expected#SUMS:}"
        if ! cyber_download "$sums_url" "$work/sums"; then rm -rf -- "$work"; return 4; fi
        expected="$(awk -v a="$asset" '$2 == a || $2 == ("*" a) {print $1; exit}' "$work/sums")"
    fi
    if [[ ! "$expected" =~ ^[[:xdigit:]]{64}$ || "$url" != "https://github.com/$repo/releases/download/"* ]]; then
        log_error "Failed to obtain valid SHA256 checksum for $repo/$asset."
        rm -rf -- "$work"
        return 9
    fi
    install_verified_binary "$url" "$dest" "$expected" || rc=$?
    rm -rf -- "$work"
    return "$rc"
}

install_cloudflared() {
    install_component_ready cloudflared && return 0
    [ -n "${CYBER_CLOUDFLARED_ARCH:-}" ] || return 3
    install_github_binary cloudflare/cloudflared "cloudflared-linux-$CYBER_CLOUDFLARED_ARCH" "$USER_BIN_DIR/cloudflared"
}

install_node_global_tool() {
    local tool="$1"
    case "$tool" in pm2|pnpm) ;; *) return 2 ;; esac
    have_command "$tool" && return 0
    install_component_ready node || return 7
    npm install --global --prefix "$HOME/.npm-global" "$tool" || return 8
    install_refresh_path
    have_command "$tool"
}

install_component() {
    local component="$1" mode="${CYBERVPS_INSTALL_MODE:-rootless}"
    install_component_ready "$component" && return 0
    case "$component" in
        core|build|desktop|cybervm)
            if install_mode_has_system_packages; then
                install_system_component "$component" && install_component_ready "$component"
                return $?
            fi
            case "$component" in
                core) install_mamba_packages git curl openssl coreutils tar gzip tmux ;;
                build) install_mamba_packages compilers cmake make pkg-config gdb ;;
                *) log_error "$component installation requires native packages; choose root or hybrid mode when available."; return 3 ;;
            esac
            ;;
        python|node|sqlite|go|rust)
            if install_mode_has_system_packages; then
                if install_system_component "$component" && install_component_ready "$component"; then return 0; fi
                log_warn "Native $component unavailable or below minimum version; trying portable installation."
            fi
            case "$component" in
                python) install_mamba_packages 'python>=3.10' pip ;;
                node) install_node ;;
                sqlite) install_mamba_packages sqlite ;;
                go) install_go ;;
                rust) install_rust ;;
            esac
            ;;
        nginx|redis)
            if install_mode_has_system_packages; then
                if install_system_component "$component" && install_component_ready "$component"; then return 0; fi
                log_warn "Native $component unavailable; trying portable fallback."
            fi
            case "$component" in
                nginx) install_mamba_packages nginx ;;
                redis)
                    log_warn "Portable Redis server unavailable in rootless mode without system packages."
                    return 8
                    ;;
            esac
            ;;
        micromamba) install_micromamba ;;
        pm2|pnpm)
            if ! install_component_ready node; then
                log_warn "$component skipped: requires Node.js and npm."
                return 7
            fi
            install_node_global_tool "$component"
            ;;
        cloudflared) install_cloudflared ;;
        ttyd)
            local arch="$CYBER_ARCH"
            [ "$arch" != armv7l ] || arch=armhf
            install_github_binary tsl0922/ttyd "ttyd.$arch" "$USER_BIN_DIR/ttyd"
            ;;
        cyberroot|agent)
            log_error "$component is not installed. Install its verified release or use an explicitly configured development checkout."
            return 3
            ;;
        *) return 2 ;;
    esac || return $?
    install_component_ready "$component" || { log_error "$component installation finished without a usable executable."; return 7; }
}

# Preserve interpreter invocation on checkouts and mounts without executable bits.
install_run_script() {
    local script="$1"
    shift
    [ -f "$script" ] && [ -r "$script" ] || return 7
    bash "$script" "$@"
}

install_profile_plan() {
    local component requirement
    printf 'Install mode: %s\nPackage manager: %s\n' "$CYBERVPS_INSTALL_MODE" "${CYBER_PACKAGE_MANAGER:-unavailable}"
    for component in "${INSTALL_COMPONENTS[@]}"; do
        requirement=optional
        if install_component_required "$component"; then requirement=required; fi
        if install_component_ready "$component"; then
            printf 'PASS %-14s existing capability (%s)\n' "$component" "$requirement"
        else
            printf 'PLAN %-14s install/repair in %s mode (%s)\n' "$component" "$CYBERVPS_INSTALL_MODE" "$requirement"
        fi
    done
    printf 'Desktop is opt-in. State stays under HOME; service activation is a separate action.\n'
}

install_profile_verify() {
    local component required_fail=0 optional_fail=0 status
    for component in "${INSTALL_COMPONENTS[@]}"; do
        if install_component_ready "$component"; then status=PASS
        elif install_component_required "$component"; then status=FAIL_REQUIRED; required_fail=$((required_fail + 1))
        else status=WARN; optional_fail=$((optional_fail + 1)); fi
        printf '%-14s %s\n' "$status" "$component"
    done
    printf 'Verification: %s required failures, %s optional unavailable.\n' "$required_fail" "$optional_fail"
    [ "$required_fail" -eq 0 ] || return 9
}

install_profile() {
    local profile="${1:-hosting}" component status rc required_fail=0 optional_fail=0
    install_profile_components "$profile" || return $?
    [ -n "${CYBERVPS_INSTALL_MODE:-}" ] || install_resolve_mode auto || return $?
    ensure_user_paths || return $?
    local state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/install" report
    mkdir -p -- "$state_dir" || return 8
    chmod 0700 "$state_dir" || return 8
    report="$(mktemp "$state_dir/transaction.XXXXXX")" || return 8
    printf 'profile\t%s\nmode\t%s\n' "$profile" "$CYBERVPS_INSTALL_MODE" > "$report"
    INSTALL_RESULTS=()
    for component in "${INSTALL_COMPONENTS[@]}"; do
        rc=0
        case "$component" in
            pm2|pnpm)
                if ! install_component_ready node; then
                    status="SKIP_DEPENDENCY"
                    rc=7
                    optional_fail=$((optional_fail + 1))
                    INSTALL_RESULTS+=("$status $component (requires node)")
                    printf '%s\t%s\t%s\n' "$component" "$status" "$rc" >> "$report"
                    continue
                fi
                ;;
        esac
        if { case "$component" in
            nginx|redis) install_run_script "$CYBERVPS_ROOT/installers/$component.sh" ;;
            *) install_component "$component" ;;
        esac; }; then status=PASS
        else
            rc=$?
            if install_component_required "$component"; then status=FAIL_REQUIRED; required_fail=$((required_fail + 1))
            else status=FAIL_OPTIONAL; optional_fail=$((optional_fail + 1)); fi
        fi
        INSTALL_RESULTS+=("$status $component (exit $rc)")
        printf '%s\t%s\t%s\n' "$component" "$status" "$rc" >> "$report"
    done
    mv -f -- "$report" "$state_dir/latest.tsv" || return 8
    log_header 'INSTALLATION COMPONENT REPORT'
    printf '%s\n' "${INSTALL_RESULTS[@]}"
    printf 'Required failures: %s | Optional failures: %s\nReport: %s\n' "$required_fail" "$optional_fail" "$state_dir/latest.tsv"
    [ "$required_fail" -eq 0 ] || return 7
    [ "$optional_fail" -eq 0 ] || return 10
}
