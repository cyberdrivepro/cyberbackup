#!/usr/bin/env bash
# Explicit, bounded network diagnostics. No probes run at library load time.
[ -n "${_CYBERVPS_NETWORK_SH_LOADED:-}" ] && return 0
_CYBERVPS_NETWORK_SH_LOADED=1

_network_dns_probe() {
    if command -v getent >/dev/null 2>&1; then
        cyber_probe getent ahosts "$1" >/dev/null 2>&1
    elif command -v nslookup >/dev/null 2>&1; then
        cyber_probe nslookup "$1" >/dev/null 2>&1
    else return 2; fi
}

_network_https_probe() {
    local url="$1" family="${2:-any}"
    local args=()
    [[ "$url" = https://* ]] || return 2
    case "$family" in 4) args+=(-4) ;; 6) args+=(-6) ;; esac
    if command -v curl >/dev/null 2>&1; then
        curl "${args[@]}" --fail --silent --location --max-redirs 3 --connect-timeout 2 --max-time 4 --proto '=https' --proto-redir '=https' --output /dev/null "$url" >/dev/null 2>&1
    elif command -v wget >/dev/null 2>&1; then
        wget "${args[@]}" --quiet --spider --timeout=4 --tries=1 --max-redirect=0 "$url" >/dev/null 2>&1
    else return 2; fi
}

detect_network() {
    CYBER_NETWORK_STATE=UNKNOWN CYBER_NETWORK_DNS=UNKNOWN
    CYBER_NETWORK_GITHUB=UNKNOWN CYBER_NETWORK_PACKAGES=UNKNOWN CYBER_NETWORK_NEUTRAL=UNKNOWN
    CYBER_NETWORK_IPV4=UNKNOWN CYBER_NETWORK_IPV6=UNKNOWN CYBER_NETWORK_PROXY=false
    if [ -n "${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-${ALL_PROXY:-${all_proxy:-}}}}}}" ]; then CYBER_NETWORK_PROXY=true; fi
    [ "${CYBERVPS_READ_ONLY:-0}" = 1 ] && return 0
    local package_url=https://deb.debian.org package_host=deb.debian.org
    case "${CYBER_PACKAGE_MANAGER:-}" in
        dnf|yum) package_url=https://mirrors.fedoraproject.org; package_host=mirrors.fedoraproject.org ;;
        apk) package_url=https://dl-cdn.alpinelinux.org; package_host=dl-cdn.alpinelinux.org ;;
        pacman) package_url=https://geo.mirror.pkgbuild.com; package_host=geo.mirror.pkgbuild.com ;;
        zypper) package_url=https://download.opensuse.org; package_host=download.opensuse.org ;;
    esac
    local pass=0 dns_pass=0 rc
    CYBER_NETWORK_DNS=FAIL
    if _network_dns_probe github.com; then dns_pass=$((dns_pass+1)); fi
    if _network_dns_probe "$package_host"; then dns_pass=$((dns_pass+1)); fi
    [ "$dns_pass" -gt 0 ] && CYBER_NETWORK_DNS=PASS
    if ! command -v getent >/dev/null 2>&1 && ! command -v nslookup >/dev/null 2>&1; then CYBER_NETWORK_DNS=UNKNOWN; fi
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        CYBER_NETWORK_STATE=UNKNOWN; return 0
    fi
    local name url
    for name in GITHUB PACKAGES NEUTRAL; do
        case "$name" in
            GITHUB) url=https://github.com ;;
            PACKAGES) url="$package_url" ;;
            NEUTRAL) url="${CYBERVPS_NETWORK_NEUTRAL_URL:-https://example.com}" ;;
        esac
        rc=0; _network_https_probe "$url" || rc=$?
        if [ "$rc" -eq 0 ]; then printf -v "CYBER_NETWORK_$name" '%s' PASS; pass=$((pass+1))
        else printf -v "CYBER_NETWORK_$name" '%s' FAIL; fi
    done
    CYBER_NETWORK_IPV4=FAIL CYBER_NETWORK_IPV6=FAIL
    if _network_https_probe https://github.com 4 || _network_https_probe "$package_url" 4; then CYBER_NETWORK_IPV4=PASS; fi
    if _network_https_probe https://github.com 6 || _network_https_probe "$package_url" 6; then CYBER_NETWORK_IPV6=PASS; fi
    if [ "$pass" -gt 0 ]; then
        CYBER_NETWORK_STATE=PARTIAL
        if [ "$pass" -eq 3 ]; then
            CYBER_NETWORK_STATE=ONLINE
            if [ "$CYBER_NETWORK_IPV4" = PASS ] && [ "$CYBER_NETWORK_IPV6" = FAIL ]; then CYBER_NETWORK_STATE=IPV4_ONLY; fi
            if [ "$CYBER_NETWORK_IPV6" = PASS ] && [ "$CYBER_NETWORK_IPV4" = FAIL ]; then CYBER_NETWORK_STATE=IPV6_ONLY; fi
        fi
    elif [ "$CYBER_NETWORK_DNS" = PASS ]; then CYBER_NETWORK_STATE=HTTPS_FAILURE
    elif [ "$CYBER_NETWORK_DNS" = FAIL ]; then CYBER_NETWORK_STATE=DNS_FAILURE
    else CYBER_NETWORK_STATE=UNKNOWN; fi
    return 0
}

print_network_summary() {
    printf 'Network: %s (proxy configured: %s)\n' "$CYBER_NETWORK_STATE" "$CYBER_NETWORK_PROXY"
    printf 'DNS: %s; GitHub: %s; package endpoint: %s; neutral endpoint: %s\n' "$CYBER_NETWORK_DNS" "$CYBER_NETWORK_GITHUB" "$CYBER_NETWORK_PACKAGES" "$CYBER_NETWORK_NEUTRAL"
    printf 'HTTPS IPv4: %s; HTTPS IPv6: %s; public inbound: UNKNOWN\n' "$CYBER_NETWORK_IPV4" "$CYBER_NETWORK_IPV6"
    [ "$CYBER_NETWORK_PROXY" = true ] && printf 'Address-family probes may reflect the configured proxy.\n'
    return 0
}
