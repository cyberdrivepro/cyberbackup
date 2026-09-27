#!/usr/bin/env bash
# tests/test-fresh-install.sh — Tests for CyberVPS fresh rebuild profiles & preflight check
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

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        log_ok "PASS: $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_error "FAIL: $msg (expected substring '$needle' in output)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

log_header "Testing fresh-install.sh Profiles & Preflight Check"

# Test 1: Help message
help_out="$(bash "$REPO_DIR/fresh-install.sh" --help 2>&1)"
assert_true "Help option exits with 0" test $? -eq 0
assert_contains "$help_out" "--profile" "Help mentions --profile option"
assert_contains "$help_out" "--dry-run" "Help mentions --dry-run option"

# Test 2: Non-interactive dry-run defaults to hosting profile and displays preflight check
dry_out="$(bash "$REPO_DIR/fresh-install.sh" --dry-run </dev/null 2>&1)"
assert_true "Non-interactive dry-run succeeds" test $? -eq 0
assert_contains "$dry_out" "PREFLIGHT ENVIRONMENT CHECK" "Output contains preflight header"
assert_contains "$dry_out" "profile: hosting" "Dry-run defaults to hosting profile"
assert_contains "$dry_out" "non-root user-space" "Preflight verifies non-root user-space"
assert_contains "$dry_out" "NOT REQUIRED" "Preflight mentions system root not required"
assert_contains "$dry_out" "NOT USED" "Preflight mentions system package manager not used"

# Test 3: Explicit profile flag selection
dev_out="$(bash "$REPO_DIR/fresh-install.sh" --dry-run --profile developer </dev/null 2>&1)"
assert_true "Developer profile dry-run succeeds" test $? -eq 0
assert_contains "$dev_out" "profile: developer" "Output shows developer profile in preflight"

# Test 4: Interactive back option (selecting 'B' exits cleanly)
back_out="$(printf "B\n" | CYBERVPS_INTERACTIVE=1 bash "$REPO_DIR/fresh-install.sh" 2>&1 || true)"
assert_contains "$back_out" "Returned to dashboard" "Selecting 'B' returns cleanly to dashboard"

# Test 5: Interactive profile selection via piped input
pipe_choice_out="$(printf "1\nn\n" | CYBERVPS_INTERACTIVE=1 bash "$REPO_DIR/fresh-install.sh" 2>&1 || true)"
assert_contains "$pipe_choice_out" "profile: minimal" "Interactive menu selects minimal profile"
assert_contains "$pipe_choice_out" "Installation cancelled by user" "Cancellation via 'n' aborts cleanly"

echo
log_header "Test Summary: $TESTS_PASSED passed, $TESTS_FAILED failed"
if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
