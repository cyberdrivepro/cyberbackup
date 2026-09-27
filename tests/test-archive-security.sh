#!/usr/bin/env bash
# tests/test-archive-security.sh — Unit test for CyberVPS archive security validation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logging.sh
source "$PROJECT_ROOT/lib/logging.sh"
# shellcheck source=lib/common.sh
source "$PROJECT_ROOT/lib/common.sh"
# shellcheck source=lib/archive.sh
source "$PROJECT_ROOT/lib/archive.sh"

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
        log_error "FAIL: $msg (expected failure but command succeeded)"
        TEST_FAILED=$((TEST_FAILED + 1))
    fi
}

log_header "Testing Archive Security Validation Engine"

# 1. Create a legitimate safe archive
mkdir -p "$TEST_TMP/safe_src/config" "$TEST_TMP/safe_src/bin"
echo "hello=world" > "$TEST_TMP/safe_src/config/app.conf"
echo "echo hi" > "$TEST_TMP/safe_src/bin/run.sh"
ln -s "run.sh" "$TEST_TMP/safe_src/bin/run_alias.sh"
tar -czf "$TEST_TMP/safe.tar.gz" -C "$TEST_TMP/safe_src" config bin

assert_true "Legitimate archive passes security validation" validate_archive_security "$TEST_TMP/safe.tar.gz"

# 2. Test extraction of legitimate archive
mkdir -p "$TEST_TMP/safe_dst"
assert_true "Safe archive extracts into staging directory" extract_archive_safe "$TEST_TMP/safe.tar.gz" "$TEST_TMP/safe_dst"
assert_true "Extracted file exists" test -f "$TEST_TMP/safe_dst/config/app.conf"

# 3. Create malicious archive with path traversal (..)
if have_command python3; then
    python3 -c "
import tarfile, io
t = tarfile.open('$TEST_TMP/traversal.tar.gz', 'w:gz')
ti = tarfile.TarInfo('../../etc/traversal_exploit.txt')
ti.size = 7
t.addfile(ti, io.BytesIO(b'exploit'))
t.close()
"
    assert_false "Archive with path traversal (..) is rejected" validate_archive_security "$TEST_TMP/traversal.tar.gz"

    mkdir -p "$TEST_TMP/traversal_dst"
    assert_false "Safe extraction blocks path traversal archive" extract_archive_safe "$TEST_TMP/traversal.tar.gz" "$TEST_TMP/traversal_dst"
    assert_false "Exploit file was not extracted" test -f "$TEST_TMP/etc/traversal_exploit.txt"
fi

# 4. Create malicious archive with absolute path (/...)
if have_command python3; then
    python3 -c "
import tarfile, io
t = tarfile.open('$TEST_TMP/abs_path.tar.gz', 'w:gz')
ti = tarfile.TarInfo('/etc/absolute_exploit.txt')
ti.size = 7
t.addfile(ti, io.BytesIO(b'exploit'))
t.close()
"
    assert_false "Archive with absolute path is rejected" validate_archive_security "$TEST_TMP/abs_path.tar.gz"
fi

# 5. Create malicious archive with absolute symlink target (-> /etc/passwd)
if have_command python3; then
    python3 -c "
import tarfile
t = tarfile.open('$TEST_TMP/sym_abs.tar.gz', 'w:gz')
ti = tarfile.TarInfo('evil_link')
ti.type = tarfile.SYMTYPE
ti.linkname = '/etc/passwd'
t.addfile(ti)
t.close()
"
    assert_false "Archive with absolute symlink target is rejected" validate_archive_security "$TEST_TMP/sym_abs.tar.gz"
fi

# 6. Create malicious archive with escaping symlink (top-level -> ../outside)
if have_command python3; then
    python3 -c "
import tarfile
t = tarfile.open('$TEST_TMP/sym_escape.tar.gz', 'w:gz')
ti = tarfile.TarInfo('top_link')
ti.type = tarfile.SYMTYPE
ti.linkname = '../outside'
t.addfile(ti)
t.close()
"
    assert_false "Archive with escaping symlink target is rejected" validate_archive_security "$TEST_TMP/sym_escape.tar.gz"
fi

# 7. Non-existent file test
assert_false "Non-existent archive is rejected" validate_archive_security "$TEST_TMP/nonexistent.tar.gz"

# 8. Empty file test
touch "$TEST_TMP/empty.tar.gz"
assert_false "Empty archive is rejected" validate_archive_security "$TEST_TMP/empty.tar.gz"

echo ""
echo "Archive security test summary: $TEST_PASSED passed, $TEST_FAILED failed."
if [ "$TEST_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
