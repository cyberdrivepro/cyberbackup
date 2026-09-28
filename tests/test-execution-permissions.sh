#!/usr/bin/env bash
# tests/test-execution-permissions.sh — Unit test for resilient script execution engine
# Verifies readable+non-executable script execution, exit code trapping, and error boundary resilience.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logging.sh
source "$PROJECT_ROOT/lib/logging.sh"
# shellcheck source=lib/execution.sh
source "$PROJECT_ROOT/lib/execution.sh"

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

TEST_PASSED=0
TEST_FAILED=0

assert_equal() {
    local expected="$1"
    local actual="$2"
    local msg="$3"
    if [ "$expected" = "$actual" ]; then
        log_ok "PASS: $msg (value: $actual)"
        TEST_PASSED=$((TEST_PASSED + 1))
    else
        log_error "FAIL: $msg (expected: '$expected', got: '$actual')"
        TEST_FAILED=$((TEST_FAILED + 1))
    fi
}

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

log_header "Testing Script Execution Engine & Error Boundary"

# 1. Readable + Executable Script
GOOD_SH="$TEST_TMP/good.sh"
cat << 'EOF' > "$GOOD_SH"
#!/usr/bin/env bash
echo "GOOD_EXECUTION"
exit 0
EOF
chmod 0755 "$GOOD_SH"

RC=0
run_cybervps_script "$GOOD_SH" >/dev/null 2>&1 || RC=$?
assert_equal "0" "$RC" "Readable + executable script executes successfully"

# 2. Readable + NON-Executable Script (chmod -x / 0644)
# This was the exact bug on the Kasm/restricted cloud VPS:
# When cloned without execute permissions, normal execution fails with Permission Denied.
# run_cybervps_script MUST invoke via Bash and succeed!
NOEXEC_SH="$TEST_TMP/noexec.sh"
cat << 'EOF' > "$NOEXEC_SH"
#!/usr/bin/env bash
echo "NOEXEC_EXECUTION_WORKED"
exit 0
EOF
chmod 0644 "$NOEXEC_SH"

RC=0
run_cybervps_script "$NOEXEC_SH" >/dev/null 2>&1 || RC=$?
assert_equal "0" "$RC" "Readable + non-executable (chmod 0644) script executes successfully via Bash dispatcher"

# 3. Missing Script -> must return 127
MISSING_SH="$TEST_TMP/does_not_exist.sh"
RC=0
run_cybervps_script "$MISSING_SH" >/dev/null 2>&1 || RC=$?
assert_equal "127" "$RC" "Missing script returns exit code 127"

# 4. Target is a Directory -> must return 126
DIR_TARGET="$TEST_TMP/somedir"
mkdir -p "$DIR_TARGET"
RC=0
run_cybervps_script "$DIR_TARGET" >/dev/null 2>&1 || RC=$?
assert_equal "126" "$RC" "Directory target returns exit code 126"

# 5. Child script returns 1 -> dispatcher must return 1 cleanly without killing caller
FAIL_1_SH="$TEST_TMP/fail1.sh"
cat << 'EOF' > "$FAIL_1_SH"
#!/usr/bin/env bash
exit 1
EOF
chmod 0644 "$FAIL_1_SH"
RC=0
run_cybervps_script "$FAIL_1_SH" >/dev/null 2>&1 || RC=$?
assert_equal "1" "$RC" "Child exit 1 is captured cleanly without killing caller"

# 6. Child script returns 126 -> dispatcher returns 126 cleanly
FAIL_126_SH="$TEST_TMP/fail126.sh"
cat << 'EOF' > "$FAIL_126_SH"
#!/usr/bin/env bash
exit 126
EOF
chmod 0644 "$FAIL_126_SH"
RC=0
run_cybervps_script "$FAIL_126_SH" >/dev/null 2>&1 || RC=$?
assert_equal "126" "$RC" "Child exit 126 is captured cleanly"

# 7. Child script returns 127 -> dispatcher returns 127 cleanly
FAIL_127_SH="$TEST_TMP/fail127.sh"
cat << 'EOF' > "$FAIL_127_SH"
#!/usr/bin/env bash
exit 127
EOF
chmod 0644 "$FAIL_127_SH"
RC=0
run_cybervps_script "$FAIL_127_SH" >/dev/null 2>&1 || RC=$?
assert_equal "127" "$RC" "Child exit 127 is captured cleanly"

# 8. Child script interrupted (130) -> dispatcher returns 130 cleanly
FAIL_130_SH="$TEST_TMP/fail130.sh"
cat << 'EOF' > "$FAIL_130_SH"
#!/usr/bin/env bash
exit 130
EOF
chmod 0644 "$FAIL_130_SH"
RC=0
run_cybervps_script "$FAIL_130_SH" >/dev/null 2>&1 || RC=$?
assert_equal "130" "$RC" "Child exit 130 (SIGINT) is captured cleanly"

# 9. Exit Code Interpreter
assert_true "Exit code 0 interpreted as Success" test "$(interpret_exit_code 0)" = "Success"
assert_true "Exit code 126 interpreted as permission/execution issue" grep -q "Execution denied" <<< "$(interpret_exit_code 126)"
assert_true "Exit code 127 interpreted as not found" grep -q "not found" <<< "$(interpret_exit_code 127)"
assert_true "Exit code 130 interpreted as cancelled" grep -q "cancelled" <<< "$(interpret_exit_code 130)"

# 10. Test Menu Resilience under Error Conditions
# Running cybervps.sh with a mock failure must NOT kill the menu process
echo -e "Testing cybervps.sh error boundary with non-executable scripts..."
chmod -x "$PROJECT_ROOT"/fresh-install.sh 2>/dev/null || true
MENU_TEST_OUTPUT=$(printf "2\n\n0\n" | bash "$PROJECT_ROOT/cybervps.sh" --menu 2>&1 || true)
chmod +x "$PROJECT_ROOT"/fresh-install.sh 2>/dev/null || true

assert_true "Menu survived non-executable child script and prompted gracefully" grep -q "Action: Install / Rebuild" <<< "$MENU_TEST_OUTPUT"
assert_true "Menu exited cleanly with 0 on user command" grep -q "Exiting CyberVPS. Goodbye!" <<< "$MENU_TEST_OUTPUT"

echo ""
echo "Execution permissions test summary: $TEST_PASSED passed, $TEST_FAILED failed."
if [ "$TEST_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
