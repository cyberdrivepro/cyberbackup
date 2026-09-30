#!/usr/bin/env bash
# tests/test-sessions.sh — Automated tests for CyberVPS persistent session manager
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

# shellcheck source=lib/sessions.sh
source "$REPO_DIR/lib/sessions.sh"

ORIG_PATH="$PATH"
MOCK_ROOT="$(mktemp -d /tmp/cybervps-test-sessions-XXXXXX)"
export HOME="$MOCK_ROOT"
export XDG_STATE_HOME="$MOCK_ROOT/.local/state"
export PATH="$ORIG_PATH:$MOCK_ROOT/.local/bin"

cleanup() {
    # Stop any leftover test sessions
    if have_command tmux; then
        tmux kill-session -t "cybervps-test-s1" 2>/dev/null || true
        tmux kill-session -t "cybervps-test-renamed" 2>/dev/null || true
        tmux kill-session -t "cybervps-test-bg" 2>/dev/null || true
    fi
    rm -rf "$MOCK_ROOT"
}
trap cleanup EXIT

echo "=== Testing Session Name Validation ==="
session_validate_name "valid-name_123"
! session_validate_name "invalid name with spaces" 2>/dev/null
! session_validate_name "bad/slash" 2>/dev/null
echo "✔ PASS: Name validation"

echo "=== Testing Session Creation ==="
session_new "test-s1" "sleep 100"
test -f "$XDG_STATE_HOME/cybervps/sessions/test-s1.json"
session_is_alive "test-s1"
echo "✔ PASS: Session creation & metadata"

echo "=== Testing Session List & Info ==="
list_out="$(session_list)"
echo "$list_out" | grep "test-s1" >/dev/null
session_info "test-s1" | grep "RUNNING" >/dev/null
echo "✔ PASS: Session list & info"

echo "=== Testing Session Rename ==="
session_rename "test-s1" "test-renamed"
test ! -f "$XDG_STATE_HOME/cybervps/sessions/test-s1.json"
test -f "$XDG_STATE_HOME/cybervps/sessions/test-renamed.json"
session_is_alive "test-renamed"
echo "✔ PASS: Session rename"

echo "=== Testing Session Logs & Stop ==="
session_logs "test-renamed" 10 >/dev/null 2>&1 || true
session_stop "test-renamed"
! session_is_alive "test-renamed"
echo "✔ PASS: Session logs & stop"

echo "=== Testing Session Clean & Kill ==="
session_new "test-s2" "sleep 100"
session_kill "test-s2"
test ! -f "$XDG_STATE_HOME/cybervps/sessions/test-s2.json"
echo "✔ PASS: Session kill & clean"

echo "=== Testing Process Persistence Across Subshell Disconnect ==="
(
    # Simulate initiating shell that exits
    session_new "test-bg" "sleep 50"
    exit 0
)
# Check that session and its process survived parent shell exit
session_is_alive "test-bg"
session_stop "test-bg"
echo "✔ PASS: Session persistence across parent disconnect"

echo "All session tests passed!"
exit 0
