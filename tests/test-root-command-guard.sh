#!/usr/bin/env bash
# tests/test-root-command-guard.sh — Unit test for Root Command Guard

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logging.sh
source "$PROJECT_ROOT/lib/logging.sh"

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

log_header "Testing Root Command Guard"

# 1. Clean repository scan must pass
assert_true "Repository has zero prohibited root commands" bash "$PROJECT_ROOT/scripts/root-command-guard.sh"

# 2. Test that sudo invocation is detected
MOCK_ROOT="$TEST_TMP/mock_repo"
mkdir -p "$MOCK_ROOT"

cat << 'EOF' > "$MOCK_ROOT/bad_sudo.sh"
#!/bin/bash
sudo apt-get install -y nginx
EOF

assert_false "Guard detects sudo apt-get command" bash "$PROJECT_ROOT/scripts/root-command-guard.sh" "$MOCK_ROOT"

# 3. Test that su root invocation is detected
cat << 'EOF' > "$MOCK_ROOT/bad_su.sh"
#!/bin/bash
su root -c "whoami"
EOF
rm -f "$MOCK_ROOT/bad_sudo.sh"

assert_false "Guard detects su root command" bash "$PROJECT_ROOT/scripts/root-command-guard.sh" "$MOCK_ROOT"

# 4. Test that comment with sudo passes cleanly
cat << 'EOF' > "$MOCK_ROOT/comment_only.sh"
#!/bin/bash
# Note: do not use sudo apt install in rootless environments
echo "All good"
EOF
rm -f "$MOCK_ROOT/bad_su.sh"

assert_true "Comments mentioning root commands are ignored" bash "$PROJECT_ROOT/scripts/root-command-guard.sh" "$MOCK_ROOT"

echo ""
echo "Root command guard test summary: $TEST_PASSED passed, $TEST_FAILED failed."
if [ "$TEST_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
