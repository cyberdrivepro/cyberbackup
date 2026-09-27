#!/usr/bin/env bash
# tests/test-backup-layout.sh — Test backup creation, metadata, and exclude rules
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

TEST_HOME="$(mktemp -d /tmp/cybervps-test-backup-XXXXXX)"
trap 'rm -rf "$TEST_HOME"' EXIT

# Set test environment
export HOME="$TEST_HOME"

# Setup simulated user directory
mkdir -p "$TEST_HOME/bin" "$TEST_HOME/config" "$TEST_HOME/services" "$TEST_HOME/projects/demo-app" "$TEST_HOME/run"
echo "echo demo" > "$TEST_HOME/bin/demo"
echo "KEY=VAL" > "$TEST_HOME/config/test.conf"
echo "port=8080" > "$TEST_HOME/services/service.conf"
echo '{"name": "demo-app"}' > "$TEST_HOME/projects/demo-app/package.json"

# Create files that MUST be excluded
mkdir -p "$TEST_HOME/projects/demo-app/node_modules/fake-pkg"
echo "module" > "$TEST_HOME/projects/demo-app/node_modules/fake-pkg/index.js"
mkdir -p "$TEST_HOME/.cache/test"
echo "cache" > "$TEST_HOME/.cache/test/cached.dat"
echo "12345" > "$TEST_HOME/run/test.pid"
touch "$TEST_HOME/run/test.sock"

# Output directory
BACKUP_OUT="$TEST_HOME/backups-out"
mkdir -p "$BACKUP_OUT"

# shellcheck source=lib/backup.sh
source "$REPO_DIR/lib/backup.sh"

echo "Testing backup engine..."

# 1. Test Dry Run
create_cybervps_backup 0 0 1 "$BACKUP_OUT"
[ ! -f "$BACKUP_OUT/latest.json" ] || { echo "FAIL: dry-run should not create latest.json"; exit 1; }
echo "PASS: Dry-run mode completed cleanly"

# 2. Test Real Backup
create_cybervps_backup 0 0 0 "$BACKUP_OUT"

# Verify latest.json
[ -f "$BACKUP_OUT/latest.json" ] || { echo "FAIL: latest.json not created"; exit 1; }
grep -q '"backup_format_version": 2' "$BACKUP_OUT/latest.json" || { echo "FAIL: backup_format_version 2 missing"; exit 1; }
grep -q '"architecture":' "$BACKUP_OUT/latest.json" || { echo "FAIL: architecture missing in metadata"; exit 1; }
echo "PASS: Metadata latest.json created and contains format version 2"

# Verify SHA256SUMS
[ -f "$BACKUP_OUT/SHA256SUMS" ] || { echo "FAIL: SHA256SUMS not created"; exit 1; }
(cd "$BACKUP_OUT" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || { echo "FAIL: SHA256SUMS check failed"; exit 1; }
echo "PASS: SHA256SUMS matches archive"

# Inspect archive contents
ARCHIVE=$(find "$BACKUP_OUT" -name "cybervps-backup-*.tar.*" | head -1)
[ -f "$ARCHIVE" ] || { echo "FAIL: Archive not found"; exit 1; }

ARCHIVE_FILES=$(tar -tf "$ARCHIVE")

# Verify inclusions
echo "$ARCHIVE_FILES" | grep -q "bin/demo" || { echo "FAIL: ~/bin/demo was not included"; exit 1; }
echo "$ARCHIVE_FILES" | grep -q "projects/demo-app/package.json" || { echo "FAIL: project file missing"; exit 1; }

# Verify exclusions
if echo "$ARCHIVE_FILES" | grep -q "node_modules"; then
    echo "FAIL: node_modules was NOT excluded from archive!"
    exit 1
fi
if echo "$ARCHIVE_FILES" | grep -q "\.cache"; then
    echo "FAIL: .cache was NOT excluded from archive!"
    exit 1
fi
if echo "$ARCHIVE_FILES" | grep -q "\.pid"; then
    echo "FAIL: .pid was NOT excluded from archive!"
    exit 1
fi
if echo "$ARCHIVE_FILES" | grep -q "\.sock"; then
    echo "FAIL: .sock was NOT excluded from archive!"
    exit 1
fi

echo "PASS: All excluded patterns were successfully excluded from archive"
echo "PASS: test-backup-layout.sh completed successfully."
exit 0
