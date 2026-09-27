#!/usr/bin/env bash
# tests/test-relative-backup.sh — Unit test for CyberVPS relative archive layout

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

assert_false() {
    local msg="$1"
    shift
    if ! "$@"; then
        log_ok "PASS: $msg"
        TEST_PASSED=$((TEST_PASSED + 1))
    else
        log_error "FAIL: $msg"
        TEST_FAILED=$((TEST_FAILED + 1))
    fi
}

log_header "Testing Relative Archive Layout Engine"

# 1. Setup isolated mock HOME
MOCK_HOME="$TEST_TMP/mock_home"
mkdir -p "$MOCK_HOME/bin" "$MOCK_HOME/config" "$MOCK_HOME/services" "$MOCK_HOME/projects/demo" "$MOCK_HOME/.config/cybervps"
echo "echo hello" > "$MOCK_HOME/bin/mytool.sh"
echo "PORT=9000" > "$MOCK_HOME/config/app.conf"
echo "#!/bin/bash" > "$MOCK_HOME/services/service.sh"
echo '{"name":"demo"}' > "$MOCK_HOME/projects/demo/package.json"
echo 'alias l="ls -la"' > "$MOCK_HOME/.bashrc"
chmod +x "$MOCK_HOME/bin/mytool.sh"

DEST_BACKUPS="$TEST_TMP/out_backups"
mkdir -p "$DEST_BACKUPS"

# Override HOME for isolated testing
ORIG_HOME="$HOME"
export HOME="$MOCK_HOME"

# Run backup creation into DEST_BACKUPS
assert_true "Backup snapshot created without error" create_cybervps_backup 0 0 0 "$DEST_BACKUPS"

export HOME="$ORIG_HOME"

# Check created archive
ARCHIVE="$(find "$DEST_BACKUPS" -name "cybervps-backup-*.tar.*" | head -1)"
assert_true "Backup archive file exists" test -f "$ARCHIVE"

# 2. Inspect members
MEMBERS="$(tar -tf "$ARCHIVE" 2>/dev/null)"

# Assert relative paths
assert_false "No members start with leading slash" grep -E '^/' <<< "$MEMBERS"
assert_false "No members contain path traversal" grep -E '(^|/)\.\.(/|$)' <<< "$MEMBERS"
assert_false "No members contain mock home path" grep -F "$MOCK_HOME" <<< "$MEMBERS"

# Assert critical relative directories are present
assert_true "Contains manifests directory" grep -E '^manifests/' <<< "$MEMBERS"
assert_true "Contains bin/mytool.sh" grep -E '^bin/mytool\.sh' <<< "$MEMBERS"
assert_true "Contains config/app.conf" grep -E '^config/app\.conf' <<< "$MEMBERS"
assert_true "Contains .bashrc" grep -E '^\.bashrc' <<< "$MEMBERS"

# Assert archive passes security scanner
assert_true "Archive passes validate_archive_security" validate_archive_security "$ARCHIVE"

# Assert latest.json integrity
LATEST_JSON="$DEST_BACKUPS/latest.json"
assert_true "latest.json exists" test -f "$LATEST_JSON"
ARCHIVE_SHA="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
JSON_SHA="$(grep -E '"sha256":' "$LATEST_JSON" | cut -d'"' -f4)"
assert_true "SHA256 in latest.json matches archive checksum" test "$ARCHIVE_SHA" = "$JSON_SHA"

echo ""
echo "Relative backup test summary: $TEST_PASSED passed, $TEST_FAILED failed."
if [ "$TEST_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
