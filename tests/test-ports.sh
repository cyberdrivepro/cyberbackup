#!/usr/bin/env bash
# tests/test-ports.sh — Unit test for ports.sh library
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

# Isolate test config in a temp directory
TEST_HOME="$(mktemp -d /tmp/cybervps-test-ports-XXXXXX)"
trap 'rm -rf "$TEST_HOME"' EXIT

export HOME="$TEST_HOME"

# shellcheck source=lib/ports.sh
source "$REPO_DIR/lib/ports.sh"

echo "Testing ports.sh..."

# 1. Test finding a free port
FREE_P="$(find_free_port 18880)"
[ -n "$FREE_P" ] || { echo "FAIL: find_free_port returned empty"; exit 1; }
[ "$FREE_P" -ge 1024 ] || { echo "FAIL: Port $FREE_P is privileged (<1024)"; exit 1; }
echo "PASS: find_free_port found: $FREE_P"

# 2. Test reserving a port
RES_PORT="$(reserve_or_select_port "TEST_SERVICE_PORT" 18881)"
[ -n "$RES_PORT" ] || { echo "FAIL: reserve_or_select_port returned empty"; exit 1; }
[ "$RES_PORT" -ge 1024 ] || { echo "FAIL: Reserved port $RES_PORT is privileged"; exit 1; }

# 3. Test idempotency of reservation
RES_PORT_2="$(reserve_or_select_port "TEST_SERVICE_PORT" 18881)"
[ "$RES_PORT" = "$RES_PORT_2" ] || { echo "FAIL: Idempotency failed: $RES_PORT != $RES_PORT_2"; exit 1; }
echo "PASS: reserve_or_select_port idempotent: $RES_PORT"

# 4. Verify file exists
[ -f "$PORTS_CONFIG_FILE" ] || { echo "FAIL: $PORTS_CONFIG_FILE not created"; exit 1; }
grep -q "^TEST_SERVICE_PORT=$RES_PORT" "$PORTS_CONFIG_FILE" || { echo "FAIL: Config not recorded in ports.env"; exit 1; }

echo "PASS: test-ports.sh completed successfully."
exit 0
