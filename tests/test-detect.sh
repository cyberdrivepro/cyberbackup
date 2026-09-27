#!/usr/bin/env bash
# tests/test-detect.sh — Unit test for detect.sh library
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

# shellcheck source=lib/detect.sh
source "$REPO_DIR/lib/detect.sh"

echo "Testing detect.sh..."

detect_environment

# Verify required variables are non-empty
[ -n "$CYBER_USER" ] || { echo "FAIL: CYBER_USER empty"; exit 1; }
[ -n "$CYBER_HOME" ] || { echo "FAIL: CYBER_HOME empty"; exit 1; }
[ -n "$CYBER_HOSTNAME" ] || { echo "FAIL: CYBER_HOSTNAME empty"; exit 1; }
[ -n "$CYBER_ARCH" ] || { echo "FAIL: CYBER_ARCH empty"; exit 1; }
[ -n "$CYBER_KERNEL" ] || { echo "FAIL: CYBER_KERNEL empty"; exit 1; }

# Architecture must be normalized (x86_64, aarch64, armv7l, etc.)
case "$CYBER_ARCH" in
    x86_64|aarch64|armv7l|arm64|i686)
        echo "PASS: CYBER_ARCH normalized correctly to $CYBER_ARCH"
        ;;
    *)
        echo "WARN: Untypical architecture: $CYBER_ARCH"
        ;;
esac

# libc must be detected
[ -n "$CYBER_LIBC" ] || { echo "FAIL: CYBER_LIBC empty"; exit 1; }
echo "PASS: CYBER_LIBC is $CYBER_LIBC ($CYBER_LIBC_VERSION)"

echo "PASS: test-detect.sh completed successfully."
exit 0
