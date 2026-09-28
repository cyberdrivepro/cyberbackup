#!/usr/bin/env bash
# Optional CyberRoot API v1 integration. Never infer host privilege from a guest.

find_cyberroot_bin() {
    if [[ -n ${CYBERROOT_BIN:-} ]]; then
        [[ -x $CYBERROOT_BIN ]] || return 1
        printf '%s\n' "$CYBERROOT_BIN"
    elif command -v cyberroot >/dev/null 2>&1; then
        command -v cyberroot
    elif [[ -x $HOME/.local/bin/cyberroot ]]; then
        printf '%s\n' "$HOME/.local/bin/cyberroot"
    elif [[ -n ${CYBERROOT_DEV_DIR:-} && -x $CYBERROOT_DEV_DIR/target/release/cyberroot ]]; then
        printf '%s\n' "$CYBERROOT_DEV_DIR/target/release/cyberroot"
    else
        return 1
    fi
}

cyberroot_check_contract() {
    local binary=$1 version api
    version=$("$binary" --version 2>/dev/null) || { printf 'CyberRoot version check failed.\n' >&2; return 9; }
    [[ $version =~ ^cyberroot[[:space:]][0-9]+\.[0-9]+\.[0-9]+ ]] || { printf 'Invalid CyberRoot version response.\n' >&2; return 9; }
    api=$("$binary" api-version 2>/dev/null) || { printf 'CyberRoot CLI API v1 is required; upgrade the optional runtime.\n' >&2; return 3; }
    [[ $api == 1 ]] || { printf 'Unsupported CyberRoot API version: %s\n' "$api" >&2; return 3; }
}

cyberroot_install_release() (
    set -euo pipefail
    local version=${1:-${CYBERROOT_RELEASE_VERSION:-}} expected=${2:-${CYBERROOT_RELEASE_SHA256:-}} arch tmp url actual binary
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $expected =~ ^[[:xdigit:]]{64}$ ]] || {
        printf 'Set CYBERROOT_RELEASE_VERSION and CYBERROOT_RELEASE_SHA256 to an official published release and its trusted SHA256.\n' >&2
        return 6
    }
    [[ $(uname -s) == Linux ]] || { printf 'CyberRoot execution requires Linux (or an existing WSL environment).\n' >&2; return 3; }
    case $(uname -m) in x86_64|aarch64) arch=$(uname -m);; *) printf 'Unsupported release architecture.\n' >&2; return 3;; esac
    command -v sha256sum >/dev/null 2>&1 || { printf 'sha256sum is required.\n' >&2; return 7; }
    tmp=$(mktemp -d)
    trap 'rm -rf -- "$tmp"' EXIT
    binary=$tmp/cyberroot
    url="https://github.com/cyberdrivepro/cyberroot/releases/download/v${version}/cyberroot-linux-${arch}"
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 300 --retry 3 --output "$binary.part" "$url" || return 4
    elif command -v wget >/dev/null 2>&1; then
        wget --https-only --timeout=30 --tries=3 --output-document="$binary.part" "$url" || return 4
    else
        printf 'curl or wget is required.\n' >&2; return 7
    fi
    actual=$(sha256sum "$binary.part"); actual=${actual%% *}
    [[ ${actual,,} == ${expected,,} ]] || { printf 'CyberRoot release checksum mismatch; installation refused.\n' >&2; return 9; }
    mv -- "$binary.part" "$binary"
    chmod 700 "$binary"
    [[ $("$binary" --version) == "cyberroot $version" ]] || { printf 'CyberRoot release version mismatch.\n' >&2; return 9; }
    cyberroot_check_contract "$binary" || return $?
    mkdir -p "$HOME/.local/bin"
    local staged
    staged=$(mktemp "$HOME/.local/bin/.cyberroot.XXXXXX")
    if ! cp -- "$binary" "$staged" || ! chmod 755 "$staged" || ! mv -f -- "$staged" "$HOME/.local/bin/cyberroot"; then
        rm -f -- "$staged"; return 8
    fi
    printf 'Verified CyberRoot %s installed to %s/.local/bin/cyberroot\n' "$version" "$HOME"
)

cyberroot_build_dev() (
    set -euo pipefail
    [[ -n ${CYBERROOT_DEV_DIR:-} && -f $CYBERROOT_DEV_DIR/Cargo.toml ]] || {
        printf 'Development builds require explicit CYBERROOT_DEV_DIR.\n' >&2; return 6
    }
    command -v cargo >/dev/null 2>&1 || { printf 'cargo is required for explicit development mode.\n' >&2; return 7; }
    cargo build --locked --release --manifest-path "$CYBERROOT_DEV_DIR/Cargo.toml" || return 8
    cyberroot_check_contract "$CYBERROOT_DEV_DIR/target/release/cyberroot" || return $?
    printf 'Development runtime ready in %s/target/release/cyberroot\n' "$CYBERROOT_DEV_DIR"
)

cyberroot_cli() {
    local action=${1:-help} binary
    [[ $# -eq 0 ]] || shift
    case $action in
        install-runtime) cyberroot_install_release "$@"; return $? ;;
        build-dev) cyberroot_build_dev; return $? ;;
        help|-h|--help)
            printf '%s\n' 'Usage: cybervps root {doctor|list|create|shell|exec|stop|snapshot|snapshots|clone|export|import|remote} ...' \
                'create DISTRO [--name NAME]; shell NAME; exec NAME -- COMMAND [ARG...]' \
                'import NAME ARCHIVE; export NAME FILE; snapshot NAME [SNAP]' \
                'install-runtime VERSION SHA256; build-dev (explicit CYBERROOT_DEV_DIR)' \
                'Guest root does not imply host root. Prefix has no filesystem isolation.'
            return 0 ;;
    esac
    binary=$(find_cyberroot_bin) || { printf 'CyberRoot is optional and not installed. Other CyberVPS features remain available.\n' >&2; return 3; }
    cyberroot_check_contract "$binary" || return $?
    case $action in
        create) "$binary" install "$@" ;;
        shell) "$binary" enter "$@" ;;
        doctor|list|info|exec|stop|snapshot|snapshots|restore-snapshot|clone|export|import|remote|repair|config|logs|gc|contract) "$binary" "$action" "$@" ;;
        start|restart) printf 'CyberRoot guest service supervision is not implemented. Use shell, exec, or remote start.\n' >&2; return 3 ;;
        *) printf 'Unknown CyberRoot action: %s\n' "$action" >&2; return 2 ;;
    esac
}

handle_cyberroot_menu() {
    local choice guest distro binary version
    while true; do
        printf '\n=== CyberRoot Linux Guest Runtime ===\n'
        printf 'Virtual guest root and host privilege are separate. Trusted workloads only.\n'
        if binary=$(find_cyberroot_bin); then
            version=$("$binary" --version 2>/dev/null) || version='version check failed'
            printf 'Runtime: %s (%s)\n' "$binary" "$version"
        else
            printf 'Runtime: optional component not installed\n'
        fi
        printf '%s\n' '[1] Doctor' '[2] List guests' '[3] Guest shell' '[4] Create Ubuntu / Debian guest' \
            '[5] List snapshots' '[6] Runtime contract' '[7] Remote SSH status' '[8] Install pinned release' '[9] Explicit development build' '[0] Back'
        read -r -p 'Selection: ' choice || return 0
        local rc=0
        if case $choice in
            0) return 0 ;;
            1) cyberroot_cli doctor ;;
            2) cyberroot_cli list ;;
            3) read -r -p 'Guest: ' guest || return 0; cyberroot_cli shell "$guest" ;;
            4) read -r -p 'Distro [ubuntu]: ' distro || return 0; read -r -p 'Guest name: ' guest || return 0; cyberroot_cli create "${distro:-ubuntu}" --name "$guest" ;;
            5) read -r -p 'Guest: ' guest || return 0; cyberroot_cli snapshots "$guest" ;;
            6) cyberroot_cli contract ;;
            7) read -r -p 'Guest: ' guest || return 0; cyberroot_cli remote status "$guest" ;;
            8) cyberroot_install_release ;;
            9) cyberroot_build_dev ;;
            *) printf 'Invalid selection.\n' ;;
        esac; then rc=0; else rc=$?; fi
        [[ $rc -eq 0 ]] || printf 'CyberRoot operation failed (exit %s). Review the message above.\n' "$rc"
        read -r -p 'Press Enter to continue...' choice || return 0
    done
}
