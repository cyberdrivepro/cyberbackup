#!/usr/bin/env bash
# tests/test-migration-paths.sh — Test configuration path translation during restore and migration
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

TEST_HOME="$(mktemp -d /tmp/cybervps-test-migrate-XXXXXX)"
trap 'rm -rf "$TEST_HOME"' EXIT

# shellcheck source=lib/restore.sh
source "$REPO_DIR/lib/restore.sh"

echo "Testing migration path translation..."

SRC_HOME="/home/alice"
DST_HOME="/home/bob"

# 1. Test translation on a managed config file
CONF_FILE="$TEST_HOME/nginx.conf"
cat << 'EOF' > "$CONF_FILE"
pid /home/alice/run/nginx.pid;
error_log /home/alice/logs/nginx_error.log;
include /home/alice/config/nginx/*.conf;
EOF

translate_managed_paths "$SRC_HOME" "$DST_HOME" "$CONF_FILE"

grep -q "/home/bob/run/nginx.pid" "$CONF_FILE" || { echo "FAIL: pid path not translated"; exit 1; }
grep -q "/home/bob/logs/nginx_error.log" "$CONF_FILE" || { echo "FAIL: error_log path not translated"; exit 1; }
grep -q "/home/bob/config/nginx" "$CONF_FILE" || { echo "FAIL: include path not translated"; exit 1; }
grep -q "/home/alice" "$CONF_FILE" && { echo "FAIL: old path still present in config"; exit 1; }
echo "PASS: translate_managed_paths accurately translated managed config paths"

# 2. Test idempotency (calling again on already translated file does nothing)
translate_managed_paths "$SRC_HOME" "$DST_HOME" "$CONF_FILE"
grep -q "/home/bob/run/nginx.pid" "$CONF_FILE" || { echo "FAIL: second call corrupted path"; exit 1; }
echo "PASS: translate_managed_paths is idempotent"

echo "PASS: test-migration-paths.sh completed successfully."
exit 0
