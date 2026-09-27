#!/usr/bin/env bash
# tests/test-restore-e2e.sh — End-to-end unit test for CyberVPS relative backup and restore

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logging.sh
source "$PROJECT_ROOT/lib/logging.sh"
# shellcheck source=lib/common.sh
source "$PROJECT_ROOT/lib/common.sh"
# shellcheck source=lib/archive.sh
source "$PROJECT_ROOT/lib/archive.sh"
# shellcheck source=lib/backup.sh
source "$PROJECT_ROOT/lib/backup.sh"
# shellcheck source=lib/restore.sh
source "$PROJECT_ROOT/lib/restore.sh"

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

TEST_PASSED=0
TEST_FAILED=0

assert_true() {
    local msg="$1"
    shift
    if "$@"; then
        log_ok "PASS: $msg"
        TEST_PASSED=$((TEST_PASSED + 1))
    else
        log_error "FAIL: $msg"
        TEST_FAILED=$((TEST_FAILED + 1))
    fi
}

log_header "Testing End-to-End Backup and Restore Cycle"

# 1. Setup Source Home
SRC_HOME="$TEST_TMP/src_home"
mkdir -p "$SRC_HOME/bin" "$SRC_HOME/config" "$SRC_HOME/services" "$SRC_HOME/projects/demo" "$SRC_HOME/.config/cybervps"
echo "echo hello from restored tool" > "$SRC_HOME/bin/mytool.sh"
echo "pid $SRC_HOME/run/nginx.pid;" > "$SRC_HOME/config/nginx.conf"
echo "#!/bin/bash" > "$SRC_HOME/services/app.sh"
echo '{"name":"demo-app"}' > "$SRC_HOME/projects/demo/package.json"
echo 'alias greet="echo welcome"' > "$SRC_HOME/.bashrc"
chmod +x "$SRC_HOME/bin/mytool.sh" "$SRC_HOME/services/app.sh"

BACKUP_DIR="$TEST_TMP/backup_vault"
mkdir -p "$BACKUP_DIR"

# 2. Perform Backup of SRC_HOME
ORIG_HOME="$HOME"
export HOME="$SRC_HOME"

assert_true "Create relative backup" create_cybervps_backup 0 0 0 "$BACKUP_DIR"

ARCHIVE="$(find "$BACKUP_DIR" -name "cybervps-backup-*.tar.*" | head -1)"
assert_true "Archive created" test -f "$ARCHIVE"

# 3. Setup Clean Destination Home
DST_HOME="$TEST_TMP/dst_home"
mkdir -p "$DST_HOME"

export HOME="$DST_HOME"
export CYBER_HOME="$DST_HOME"

# 4. Perform Restore into DST_HOME
assert_true "Restore backup into destination" restore_cybervps_backup "$ARCHIVE" 0 0

export HOME="$ORIG_HOME"
export CYBER_HOME="$ORIG_HOME"

# 5. Verify restored structure in DST_HOME
assert_true "Restored bin/mytool.sh exists" test -f "$DST_HOME/bin/mytool.sh"
assert_true "Restored bin/mytool.sh is executable" test -x "$DST_HOME/bin/mytool.sh"
assert_true "Restored config/nginx.conf exists" test -f "$DST_HOME/config/nginx.conf"
assert_true "Restored services/app.sh exists" test -f "$DST_HOME/services/app.sh"
assert_true "Restored projects/demo/package.json exists" test -f "$DST_HOME/projects/demo/package.json"

# 6. Verify managed path translation
assert_true "Managed path was translated to destination home" grep -F "$DST_HOME/run/nginx.pid" "$DST_HOME/config/nginx.conf"

echo ""
echo "Restore E2E test summary: $TEST_PASSED passed, $TEST_FAILED failed."
if [ "$TEST_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
