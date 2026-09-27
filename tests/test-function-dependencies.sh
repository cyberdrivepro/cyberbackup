#!/usr/bin/env bash
# tests/test-function-dependencies.sh — Automated test for static function dependency audit
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"

TESTS_PASSED=0
TESTS_FAILED=0

assert_true() {
    local msg="$1"
    shift
    if "$@"; then
        log_ok "PASS: $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_error "FAIL: $msg"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

log_header "Testing Function Dependencies and Static Call Resolution"

# Test 1: Full codebase audit passes with exit code 0
audit_output="$(bash "$REPO_DIR/scripts/audit-bash-dependencies.sh" 2>&1)"
audit_rc=$?

assert_true "Codebase audit exits with 0" test "$audit_rc" -eq 0
assert_true "Audit output reports passed status" grep -q "PASS" <<< "$audit_output"
assert_true "No undefined function references found" test "${audit_output#*UNDEFINED}" = "$audit_output"

# Test 2: Regression test — ensure ensure_cybervps_profile is nowhere in codebase
assert_true "ensure_cybervps_profile is completely removed" test "$(grep -rn "ensure_cybervps_profile" "$REPO_DIR/lib" 2>/dev/null | wc -l)" -eq 0

# Test 3: Regression test — init_ports_config is defined in lib/ports.sh
assert_true "init_ports_config is defined in lib/ports.sh" grep -q "init_ports_config()" "$REPO_DIR/lib/ports.sh"

echo
log_header "Function Dependency Test Summary: $TESTS_PASSED passed, $TESTS_FAILED failed"
if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
