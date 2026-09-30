#!/usr/bin/env bash
# tests/test-guest-fallback.sh — Verify Linux guest auto fallback, defaults, and root bypass
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

TMP_SANDBOX="$(mktemp -d)"
export XDG_DATA_HOME="$TMP_SANDBOX/data"
export XDG_CONFIG_HOME="$TMP_SANDBOX/config"
trap 'rm -rf "$TMP_SANDBOX"' EXIT

# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$REPO_DIR/lib/detect.sh"
# shellcheck source=lib/cyberroot.sh
source "$REPO_DIR/lib/cyberroot.sh"

# Mock detect_environment so test runner identity doesn't overwrite simulated privilege
detect_environment() { return 0; }

echo "=== Test 1: Native root bypass in guest enter ==="
export CYBER_PRIVILEGE_MODE="CONTAINER_ROOT"
export CYBER_IS_ROOT=true

mock_shell_log="$(mktemp)"
mock_shell_bin="$(mktemp)"
cat << MOCK > "$mock_shell_bin"
#!/usr/bin/env bash
echo "GUEST_ROOT_BYPASS: env=\$CYBERVPS_HOST_SHELL" > "$mock_shell_log"
exit 0
MOCK
chmod 0755 "$mock_shell_bin"

SHELL="$mock_shell_bin" cyber_guest_enter "main"
if grep -q "GUEST_ROOT_BYPASS: env=1" "$mock_shell_log"; then
    echo "PASS: cyber_guest_enter bypassed directly to native shell on root"
else
    echo "FAIL: Root bypass failed"
    rm -f "$mock_shell_log" "$mock_shell_bin"
    exit 1
fi
rm -f "$mock_shell_log" "$mock_shell_bin"

echo "=== Test 2: Preferred backend auto discovery and fallback ==="
# Unset any explicit version env
unset CYBERROOT_RELEASE_VERSION CYBERROOT_RELEASE_SHA256 || true

# Mock cyber_proot_ensure_bin so it doesn't do a live network download during unit test
cyber_proot_ensure_bin() {
    return 0
}

# In normal mode when no CyberRoot release is published, install_preferred_backend must return 0
rc=0
cyber_install_preferred_backend || rc=$?
if [ "$rc" -eq 0 ]; then
    echo "PASS: Preferred backend fallback succeeded gracefully without fatal error"
else
    echo "FAIL: Expected return code 0, got $rc"
    exit 1
fi

echo "=== Test 3: Guest Doctor Output ==="
doctor_out="$(cyber_guest_doctor 2>&1)"
if echo "$doctor_out" | grep -q "CYBERVPS GUEST RUNTIME DOCTOR"; then
    echo "PASS: Guest doctor executed cleanly"
else
    echo "FAIL: Doctor output missing"
    exit 1
fi

echo "All guest fallback tests passed."
exit 0
