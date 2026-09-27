#!/usr/bin/env bash
# tests/test-idempotency.sh — Verify that repeated operations are safe and idempotent
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

TEST_HOME="$(mktemp -d /tmp/cybervps-test-idempotency-XXXXXX)"
trap 'rm -rf "$TEST_HOME"' EXIT
export HOME="$TEST_HOME"

# shellcheck source=lib/services.sh
source "$REPO_DIR/lib/services.sh"

echo "Testing idempotency and service management..."

# 1. Test Login Recovery Idempotency
touch "$TEST_HOME/.bashrc"
setup_login_recovery
setup_login_recovery
setup_login_recovery

COUNT=$(grep -c "# >>> CYBERVPS LOGIN RECOVERY >>>" "$TEST_HOME/.bashrc" || true)
[ "$COUNT" -eq 1 ] || { echo "FAIL: Login recovery duplicated: count=$COUNT"; exit 1; }
echo "PASS: setup_login_recovery is strictly idempotent (1 block present)"

disable_login_recovery
grep -q "# >>> CYBERVPS LOGIN RECOVERY >>>" "$TEST_HOME/.bashrc" && { echo "FAIL: Block was not removed"; exit 1; }
echo "PASS: disable_login_recovery cleanly removed block"

# 2. Test CLI helper installation
install_service_cli_helpers
[ -x "$TEST_HOME/bin/cybervps-status" ] || { echo "FAIL: cybervps-status not created or not executable"; exit 1; }
[ -x "$TEST_HOME/bin/cybervps-start" ] || { echo "FAIL: cybervps-start not created"; exit 1; }
[ -x "$TEST_HOME/bin/cybervps-stop" ] || { echo "FAIL: cybervps-stop not created"; exit 1; }

# Call again to ensure it overwrites cleanly
install_service_cli_helpers
echo "PASS: install_service_cli_helpers succeeded cleanly"

# 3. Test Process Backend Detection
BACKEND="$(get_process_backend)"
[ -n "$BACKEND" ] || { echo "FAIL: get_process_backend returned empty"; exit 1; }
echo "PASS: Detected process backend: $BACKEND"

echo "PASS: test-idempotency.sh completed successfully."
exit 0
