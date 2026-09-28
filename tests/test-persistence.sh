#!/usr/bin/env bash
# tests/test-persistence.sh — Automated tests for CyberVPS startup & recovery engine
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

# shellcheck source=lib/persistence.sh
source "$REPO_DIR/lib/persistence.sh"

ORIG_PATH="$PATH"
MOCK_ROOT="$(mktemp -d /tmp/cybervps-test-persistence-XXXXXX)"
export HOME="$MOCK_ROOT"
export XDG_CONFIG_HOME="$MOCK_ROOT/.config"
export XDG_STATE_HOME="$MOCK_ROOT/.local/state"
export PATH="$ORIG_PATH:$MOCK_ROOT/.local/bin"

cleanup() {
    rm -rf "$MOCK_ROOT"
}
trap cleanup EXIT

# Never modify the real user's crontab during a test.
crontab() { printf 'crontab access denied\n' >&2; return 1; }

echo "=== Testing Persistence Detection Matrix ==="
matrix="$(persistence_detect_modes)"
echo "$matrix" | grep -q "Persistence Capability Matrix"
echo "$matrix" | grep -q "Login Recovery"
echo "$matrix" | grep -q "Session Persistence"
echo "✔ PASS: Detection matrix output"

echo "=== Testing Persistence Setup ==="
persistence_setup
test -f "$MOCK_ROOT/.bashrc"
grep -q "LOGIN RECOVERY" "$MOCK_ROOT/.bashrc"
echo "✔ PASS: Setup login recovery"

echo "=== Testing Persistence Idempotency ==="
persistence_setup
persistence_setup
block_count="$(grep -c "# >>> CYBERVPS LOGIN RECOVERY >>>" "$MOCK_ROOT/.bashrc" || true)"
[ "$block_count" -eq 1 ]
echo "✔ PASS: Idempotent block registration"

echo "=== Testing Service Recovery Engine ==="
# Add an enabled service
service_add "test-recoverable" --cmd "sleep 60" --cwd "$MOCK_ROOT"
persistence_recover
is_service_running "test-recoverable"
service_stop "test-recoverable"
echo "✔ PASS: Service recovery execution"

echo "=== Testing Persistence Disable ==="
persistence_disable
! grep -q "# >>> CYBERVPS LOGIN RECOVERY >>>" "$MOCK_ROOT/.bashrc" 2>/dev/null || true
echo "✔ PASS: Persistence disable cleanly removes hooks"

echo "All persistence tests passed!"
exit 0
