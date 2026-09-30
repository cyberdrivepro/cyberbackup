#!/usr/bin/env bash
# tests/test-connect.sh — Test remote connection management, SSH redaction & tunnels
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

# Temporary config directory
TMP_CONFIG="$(mktemp -d)"
export XDG_CONFIG_HOME="$TMP_CONFIG"
trap 'rm -rf "$TMP_CONFIG"' EXIT

# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"
# shellcheck source=lib/connect.sh
source "$REPO_DIR/lib/connect.sh"

echo "=== Test 1: SSH Target Storage and Retrieval ==="
test_target="qBFBVnrYiExoq0iSEH4bpUy4zQxaYg89@ssh.app.daytona.io"
connect_set_ssh_target "$test_target"

retrieved="$(connect_get_ssh_target)"
if [ "$retrieved" = "$test_target" ]; then
    echo "PASS: Target saved and retrieved identically"
else
    echo "FAIL: Expected '$test_target', got '$retrieved'"
    exit 1
fi

echo "=== Test 2: Target Redaction ==="
redacted="$(connect_redact_ssh "$test_target")"
if [ "$redacted" = "ssh ********@ssh.app.daytona.io" ]; then
    echo "PASS: Target token redacted securely: $redacted"
else
    echo "FAIL: Redaction failed, got: $redacted"
    exit 1
fi

echo "=== Test 3: Clear Target ==="
connect_clear_ssh_target
if ! connect_get_ssh_target >/dev/null 2>&1; then
    echo "PASS: Target cleared successfully"
else
    echo "FAIL: Target still present after clear"
    exit 1
fi

echo "=== Test 4: CLI Show with Flag ==="
connect_set_ssh_target "$test_target"
show_out="$(cybervps_connect_ssh --show)"
if [ "$show_out" = "ssh $test_target" ]; then
    echo "PASS: cybervps connect ssh --show returns full command"
else
    echo "FAIL: --show returned '$show_out'"
    exit 1
fi

echo "=== Test 5: Connection Doctor Output ==="
doctor_out="$(cybervps_connect_doctor 2>&1)"
if echo "$doctor_out" | grep -q "REMOTE ACCESS DOCTOR"; then
    echo "PASS: Doctor output generated correctly"
else
    echo "FAIL: Doctor output missing title"
    exit 1
fi

echo "All connection tests passed."
exit 0
