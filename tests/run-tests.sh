#!/usr/bin/env bash
# tests/run-tests.sh — Test runner for CyberVPS test suite
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

PASSED=0
FAILED=0
SKIPPED=0

echo "========================================"
echo "    CyberVPS Automated Test Runner      "
echo "========================================"
echo

for test_script in "$TEST_DIR"/test-*.sh "$TEST_DIR"/test_*.sh; do
    [ -f "$test_script" ] || continue
    test_name="$(basename "$test_script")"
    echo "Running: $test_name..."
    chmod +x "$test_script"
    run_cmd="bash"
    if command -v timeout >/dev/null 2>&1; then
        run_cmd="timeout 45s bash"
    fi
    if $run_cmd "$test_script"; then
        echo "RESULT: $test_name -> PASSED"
        PASSED=$((PASSED + 1))
    else
        echo "RESULT: $test_name -> FAILED (exit code: $?)"
        FAILED=$((FAILED + 1))
    fi
    echo "----------------------------------------"
done

echo
echo "========================================"
echo "TEST SUMMARY:"
echo "  Passed:  $PASSED"
echo "  Failed:  $FAILED"
echo "  Skipped: $SKIPPED"
echo "========================================"

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
