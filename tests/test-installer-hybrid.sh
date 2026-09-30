#!/usr/bin/env bash
# tests/test-installer-hybrid.sh — Verify hybrid mode package preference & dependency blocking
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"
# shellcheck source=lib/install.sh
source "$REPO_DIR/lib/install.sh"

echo "=== Test 1: install_mode_has_system_packages in hybrid & root mode ==="
INSTALL_MODE="hybrid"
CYBER_SYSTEM_PACKAGES="AVAILABLE"
cyber_can_admin() { return 0; }
if install_mode_has_system_packages; then
    echo "PASS: hybrid mode has system packages when available and admin"
else
    echo "FAIL: hybrid mode should allow system packages"
    exit 1
fi

INSTALL_MODE="rootless"
if ! install_mode_has_system_packages; then
    echo "PASS: rootless mode does not have system packages"
else
    echo "FAIL: rootless mode should not have system packages"
    exit 1
fi

echo "=== Test 2: Package mappings for redis and nginx ==="
install_package_names apt-get redis
names="${INSTALL_PACKAGES[*]}"
if echo "$names" | grep -q "redis-server"; then
    echo "PASS: apt-get redis maps to redis-server"
else
    echo "FAIL: apt-get redis should map to redis-server, got: $names"
    exit 1
fi

install_package_names apt-get nginx
names_nginx="${INSTALL_PACKAGES[*]}"
if echo "$names_nginx" | grep -q "nginx"; then
    echo "PASS: apt-get nginx maps to nginx"
else
    echo "FAIL: apt-get nginx should map to nginx, got: $names_nginx"
    exit 1
fi

echo "=== Test 3: pm2/pnpm dependency blocking when Node is missing ==="
# Temporarily override install_component_ready
install_component_ready() {
    local comp="$1"
    if [ "$comp" = "node" ]; then return 1; fi
    return 0
}

# In install_profile, pm2 must be skipped as SKIP_DEPENDENCY when node is not ready
CYBERVPS_INSTALL_COMPONENTS="pm2,pnpm"
CYBERVPS_INSTALL_MODE="rootless"
INSTALL_RESULTS=()
install_profile custom || true

if printf '%s\n' "${INSTALL_RESULTS[@]}" | grep -q "SKIP_DEPENDENCY pm2"; then
    echo "PASS: pm2/pnpm marked as SKIP_DEPENDENCY when node is missing"
else
    echo "FAIL: pm2/pnpm not skipped properly: ${INSTALL_RESULTS[*]}"
    exit 1
fi

echo "All hybrid installer tests passed."
exit 0
