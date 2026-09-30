#!/usr/bin/env bash
# tests/test-services.sh — Automated tests for CyberVPS persistent service manager
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

# shellcheck source=lib/services.sh
source "$REPO_DIR/lib/services.sh"

ORIG_PATH="$PATH"
MOCK_ROOT="$(mktemp -d /tmp/cybervps-test-services-XXXXXX)"
export HOME="$MOCK_ROOT"
export XDG_CONFIG_HOME="$MOCK_ROOT/.config"
export XDG_STATE_HOME="$MOCK_ROOT/.local/state"
export PATH="$ORIG_PATH:$MOCK_ROOT/.local/bin"

cleanup() {
    service_stop "test-app" 2>/dev/null || true
    service_stop "test-bg-svc" 2>/dev/null || true
    service_stop "test-collision" 2>/dev/null || true
    rm -rf "$MOCK_ROOT"
}
trap cleanup EXIT

echo "=== Testing Service Registration ==="
service_add "test-app" --cmd "sleep 60" --cwd "$MOCK_ROOT" --port "19999" --health-type "process"
test -f "$XDG_CONFIG_HOME/cybervps/services/test-app.json"
echo "✔ PASS: Service registration"

echo "=== Testing Service List & Info ==="
list_out="$(service_list)"
echo "$list_out" | grep "test-app" >/dev/null
service_info "test-app" | grep "sleep 60" >/dev/null
echo "✔ PASS: Service list & info"

echo "=== Testing Service Start ==="
service_start "test-app"
is_service_running "test-app"
echo "✔ PASS: Service start"

echo "=== Testing Service Health & Status ==="
service_health "test-app" | grep "PASS" >/dev/null
service_status "test-app" | grep "RUNNING" >/dev/null
echo "✔ PASS: Service health & status"

echo "=== Testing Service Reload & Logs ==="
service_reload "test-app"
service_logs "test-app" --lines 10 >/dev/null
echo "✔ PASS: Service reload & logs"

echo "=== Testing Service Enable / Disable ==="
service_disable "test-app"
service_info "test-app" | grep '"enabled": false' >/dev/null
service_enable "test-app"
service_info "test-app" | grep '"enabled": true' >/dev/null
echo "✔ PASS: Service enable/disable"

echo "=== Testing Service Stop ==="
service_stop "test-app"
! is_service_running "test-app"
echo "✔ PASS: Service stop"

echo "=== Testing Service Persistence Across Parent Subshell Exit ==="
(
    service_start "test-app"
    exit 0
)
is_service_running "test-app"
service_stop "test-app"
echo "✔ PASS: Service persistence across parent disconnect"

echo "=== Testing Service Removal ==="
service_remove "test-app"
test ! -f "$XDG_CONFIG_HOME/cybervps/services/test-app.json"
echo "✔ PASS: Service removal"

echo "All service tests passed!"
exit 0
