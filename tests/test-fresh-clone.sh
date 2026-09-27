#!/usr/bin/env bash
# tests/test-fresh-clone.sh — Fresh clone simulation test with non-executable child scripts
# Validates that a freshly cloned repository functions under restricted filemodes.

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

log_header "Testing Fresh Clone Simulation with Restricted Filemodes"

CLONE_DIR="$TEST_TMP/fresh_clone"
mkdir -p "$CLONE_DIR"

# 1. Copy repository files to simulate fresh clone (excluding .git)
log_info "Creating simulated fresh clone in $CLONE_DIR..."
tar --exclude=.git -cf - -C "$PROJECT_ROOT" . | tar -xf - -C "$CLONE_DIR"

# 2. Strip executable bits from ALL scripts in clone (chmod 0644)
# Simulates git clone on restricted filesystem or default umask without executable permissions
log_info "Stripping executable bits from all .sh files (chmod 0644)..."
find "$CLONE_DIR" -type f -name "*.sh" -exec chmod 0644 {} +

# Verify at least one script is non-executable
assert_true "Scripts are indeed non-executable" test ! -x "$CLONE_DIR/fresh-install.sh"
assert_true "Scripts are indeed non-executable" test ! -x "$CLONE_DIR/verify.sh"

# 3. Test running cybervps.sh using canonical Bash command
log_info "Testing canonical 'bash cybervps.sh' invocation..."
OUTPUT=$(printf "8\n\n0\n" | bash "$CLONE_DIR/cybervps.sh" --menu 2>&1 || true)

assert_true "Dashboard rendered successfully" grep -q "CYBERVPS • ROOTLESS CLOUD CONTROL CENTER" <<< "$OUTPUT"
assert_true "Status menu rendered without Permission Denied" grep -q "=== CyberVPS System Status" <<< "$OUTPUT"
assert_true "Exited cleanly on option 0" grep -q "Exiting CyberVPS. Goodbye!" <<< "$OUTPUT"

# 4. Test self-repair mode on non-executable clone
log_info "Testing 'bash cybervps.sh --repair'..."
REPAIR_OUTPUT=$(bash "$CLONE_DIR/cybervps.sh" --repair 2>&1 || true)

assert_true "Self-repair completed successfully" grep -q "CyberVPS self-repair finished successfully" <<< "$REPAIR_OUTPUT"

# Verify that repair restored +x on user-owned scripts
assert_true "Self-repair restored execute permission on fresh-install.sh" test -x "$CLONE_DIR/fresh-install.sh"
assert_true "Self-repair restored execute permission on verify.sh" test -x "$CLONE_DIR/verify.sh"

echo ""
echo "Fresh clone test summary: $TEST_PASSED passed, $TEST_FAILED failed."
if [ "$TEST_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
