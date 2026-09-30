#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/network.sh
source "$REPO_DIR/lib/network.sh"
passed=0
assert_eq() { [ "$1" = "$2" ] || { echo "FAIL: $3 ($1 != $2)"; exit 1; }; passed=$((passed+1)); }
_network_dns_probe() { [ "$fixture_dns" = true ]; }
_network_https_probe() {
    [ "$fixture_https" = true ] || return 1
    [ "${2:-any}" != 6 ] || return 1
    case "$1" in https://github.com|https://deb.debian.org) return 0 ;; *) [ "$fixture_neutral" = true ] ;; esac
}
CYBER_PACKAGE_MANAGER=apt-get
fixture_dns=true fixture_https=true fixture_neutral=false
detect_network
assert_eq "$CYBER_NETWORK_STATE" PARTIAL 'one blocked endpoint does not mean offline'
assert_eq "$CYBER_NETWORK_GITHUB" PASS 'reachable GitHub'
assert_eq "$CYBER_NETWORK_PACKAGES" PASS 'reachable distro endpoint'
fixture_neutral=true
detect_network
assert_eq "$CYBER_NETWORK_STATE" IPV4_ONLY 'IPv4 connectivity with IPv6 absent'
fixture_https=false
detect_network
assert_eq "$CYBER_NETWORK_STATE" HTTPS_FAILURE 'DNS works but HTTPS blocked'
fixture_dns=false
detect_network
assert_eq "$CYBER_NETWORK_STATE" DNS_FAILURE 'failed DNS without claiming proof of offline'
CYBERVPS_READ_ONLY=1
_network_dns_probe() { echo 'FAIL: read-only invoked probe' >&2; exit 99; }
detect_network
assert_eq "$CYBER_NETWORK_STATE" UNKNOWN 'read-only skips probing'
printf 'PASS: %s network assertions\n' "$passed"
