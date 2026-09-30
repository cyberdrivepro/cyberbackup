#!/usr/bin/env bash
# tests/test-public-access.sh — Verify one-command public access and port validation
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

TMP_SANDBOX="$(mktemp -d)"
export XDG_CONFIG_HOME="$TMP_SANDBOX/config"
export XDG_STATE_HOME="$TMP_SANDBOX/state"
trap 'rm -rf "$TMP_SANDBOX"' EXIT

# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"
# shellcheck source=lib/public.sh
source "$REPO_DIR/lib/public.sh"

echo "=== Test 1: cybervps public help ==="
help_out="$(cybervps_public_cli help 2>&1)"
if echo "$help_out" | grep -q "One-Command Public Access"; then
    echo "PASS: Public CLI help displayed"
else
    echo "FAIL: Public CLI help missing"
    exit 1
fi

echo "=== Test 2: Port Validation ==="
# Out of range port
rc=0
cybervps_public_start_port 99999 >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
    echo "PASS: Invalid port 99999 rejected with return code 2"
else
    echo "FAIL: Expected return code 2, got $rc"
    exit 1
fi

# Non-numeric port
rc=0
cybervps_public_start_port "abc" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
    echo "PASS: Non-numeric port 'abc' rejected with return code 2"
else
    echo "FAIL: Expected return code 2 for non-numeric port, got $rc"
    exit 1
fi

echo "=== Test 3: Public Auth Generation & Retrieval ==="
webterm_ensure_auth
auth_out="$(cybervps_public_auth_show 2>&1)"
if echo "$auth_out" | grep -q "Username : cybervps" && echo "$auth_out" | grep -q "Password :"; then
    echo "PASS: Credentials retrieved and displayed properly via --show"
else
    echo "FAIL: Credentials output incorrect: $auth_out"
    exit 1
fi

echo "=== Test 4: Public Status Display ==="
status_out="$(cybervps_public_status 2>&1)"
if echo "$status_out" | grep -q "Web Terminal" && echo "$status_out" | grep -q "Cloudflare"; then
    echo "PASS: Public status rendered cleanly"
else
    echo "FAIL: Status output missing required components"
    exit 1
fi

echo "All public access tests passed."
exit 0
