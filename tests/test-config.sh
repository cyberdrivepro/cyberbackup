#!/usr/bin/env bash
# tests/test-config.sh — Unit test for config parsing, locking, and marked blocks in common.sh
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

TEST_HOME="$(mktemp -d /tmp/cybervps-test-config-XXXXXX)"
trap 'rm -rf "$TEST_HOME"' EXIT
export HOME="$TEST_HOME"

# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"

echo "Testing common.sh (config, locking, blocks)..."

# 1. Test parse_env_file
CFG="$TEST_HOME/test.env"
cat << 'EOF' > "$CFG"
# Comment line
CYBERVPS_ENV_NAME="hosting"
CYBERVPS_LOG_LEVEL='debug'
WEB_PORT=8090
MALICIOUS_KEY=should_be_ignored
EOF

parse_env_file "$CFG"
[ "${CYBERVPS_ENV_NAME:-}" = "hosting" ] || { echo "FAIL: CYBERVPS_ENV_NAME not parsed"; exit 1; }
[ "${CYBERVPS_LOG_LEVEL:-}" = "debug" ] || { echo "FAIL: CYBERVPS_LOG_LEVEL not parsed"; exit 1; }
[ "${WEB_PORT:-}" = "8090" ] || { echo "FAIL: WEB_PORT not parsed"; exit 1; }
[ -z "${MALICIOUS_KEY:-}" ] || { echo "FAIL: MALICIOUS_KEY should not be exported"; exit 1; }
echo "PASS: parse_env_file parsed expected keys and ignored unauthorized keys"

# 2. Test Locking
acquire_lock "testlock" || { echo "FAIL: Failed to acquire lock"; exit 1; }
# Trying to acquire same lock in subshell should fail
if ( acquire_lock "testlock" ) 2>/dev/null; then
    echo "FAIL: Concurrent acquire_lock should have failed"
    exit 1
fi
release_lock || { echo "FAIL: Failed to release lock"; exit 1; }
echo "PASS: Locking and concurrency check passed"

# 3. Test Marked Blocks
TARGET_FILE="$TEST_HOME/.bashrc"
echo "# Pre-existing bashrc content" > "$TARGET_FILE"

BLOCK_CONTENT='export CYBERVPS_RECOVERY=1'
ensure_marked_block "$TARGET_FILE" "LOGIN RECOVERY" "$BLOCK_CONTENT"

# Check marker exists
grep -q "# >>> CYBERVPS LOGIN RECOVERY >>>" "$TARGET_FILE" || { echo "FAIL: Marker start missing"; exit 1; }
grep -q "export CYBERVPS_RECOVERY=1" "$TARGET_FILE" || { echo "FAIL: Block content missing"; exit 1; }

# Call again to verify idempotency (no duplicate blocks)
ensure_marked_block "$TARGET_FILE" "LOGIN RECOVERY" "$BLOCK_CONTENT"
COUNT=$(grep -c "# >>> CYBERVPS LOGIN RECOVERY >>>" "$TARGET_FILE" || true)
[ "$COUNT" -eq 1 ] || { echo "FAIL: Duplicate block detected (count=$COUNT)"; exit 1; }
echo "PASS: ensure_marked_block is idempotent"

# Remove marked block
remove_marked_block "$TARGET_FILE" "LOGIN RECOVERY"
grep -q "# >>> CYBERVPS LOGIN RECOVERY >>>" "$TARGET_FILE" && { echo "FAIL: Marker not removed"; exit 1; }
grep -q "# Pre-existing bashrc content" "$TARGET_FILE" || { echo "FAIL: Pre-existing content was destroyed"; exit 1; }
echo "PASS: remove_marked_block cleanly removed block and preserved file contents"

echo "PASS: test-config.sh completed successfully."
exit 0
