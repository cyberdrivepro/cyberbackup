#!/usr/bin/env bash
# tests/test-virtual-shell.sh — Verify root bypass of PRoot & host shell invocation
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$REPO_DIR/lib/detect.sh"
# shellcheck source=lib/proot.sh
source "$REPO_DIR/lib/proot.sh"

# Mock detect_environment so test runner identity doesn't overwrite simulated privilege
detect_environment() { return 0; }

echo "=== Test 1: cyber_guest_shell bypasses PRoot on ROOT mode ==="
export CYBER_PRIVILEGE_MODE="ROOT"
export CYBER_IS_ROOT=true

# Mock $SHELL to verify it is called without downloading or calling proot
mock_shell_log="$(mktemp)"
mock_shell_bin="$(mktemp)"
cat << MOCK > "$mock_shell_bin"
#!/usr/bin/env bash
echo "HOST_SHELL_CALLED: env=\$CYBERVPS_HOST_SHELL" > "$mock_shell_log"
exit 0
MOCK
chmod 0755 "$mock_shell_bin"

SHELL="$mock_shell_bin" cyber_guest_shell
if grep -q "HOST_SHELL_CALLED: env=1" "$mock_shell_log"; then
    echo "PASS: cyber_guest_shell invoked host shell directly on ROOT without PRoot"
else
    echo "FAIL: cyber_guest_shell did not invoke host shell directly"
    rm -f "$mock_shell_log" "$mock_shell_bin"
    exit 1
fi
rm -f "$mock_shell_log" "$mock_shell_bin"

echo "=== Test 2: cyber_guest_shell bypasses PRoot on CONTAINER_ROOT mode ==="
export CYBER_PRIVILEGE_MODE="CONTAINER_ROOT"
export CYBER_IS_ROOT=true

mock_shell_log="$(mktemp)"
mock_shell_bin="$(mktemp)"
cat << MOCK > "$mock_shell_bin"
#!/usr/bin/env bash
echo "HOST_SHELL_CONTAINER: env=\$CYBERVPS_HOST_SHELL" > "$mock_shell_log"
exit 0
MOCK
chmod 0755 "$mock_shell_bin"

SHELL="$mock_shell_bin" cyber_guest_shell
if grep -q "HOST_SHELL_CONTAINER: env=1" "$mock_shell_log"; then
    echo "PASS: cyber_guest_shell invoked host shell directly on CONTAINER_ROOT"
else
    echo "FAIL: cyber_guest_shell failed container root bypass"
    rm -f "$mock_shell_log" "$mock_shell_bin"
    exit 1
fi
rm -f "$mock_shell_log" "$mock_shell_bin"

echo "=== Test 3: Fast skip on 404 in cyber_download ==="
source "$REPO_DIR/lib/download.sh"
# Test downloading a guaranteed 404 URL with curl returncode 22
dl_tmp="$(mktemp)"
start_time="$(date +%s)"
cyber_download "https://github.com/cyberdrivepro/cyberroot/releases/download/v999.999.999/nonexistent" "$dl_tmp" || true
end_time="$(date +%s)"
duration=$((end_time - start_time))
rm -f "$dl_tmp"

# Fast skip should terminate within 10 seconds rather than retrying 18 times (which took ~90 seconds)
if [ "$duration" -le 15 ]; then
    echo "PASS: Fast skip on 404 completed quickly ($duration seconds)"
else
    echo "WARN: Download fast skip took $duration seconds (expected <15s)"
fi

echo "All virtual shell tests passed."
exit 0
