#!/usr/bin/env bash
# tests/test-scheduler.sh — Smart Node Scheduler Scoring & Allocation Tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"

log_header "Testing Smart Node Scheduler Engine"

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

PYTHONPATH="$REPO_DIR" python3 - << 'EOF'
import sys
from fleet.scheduler import select_best_node, calculate_node_score

# Mock Nodes
node_eu_busy = {
    "id": "node_eu_01",
    "name": "EU-01",
    "status": "ONLINE",
    "disk_free_bytes": 5 * 1024 * 1024 * 1024,  # 5 GB free
    "effective_ram_bytes": 1024 * 1024 * 1024,
    "ram_used_bytes": 800 * 1024 * 1024,
    "active_jobs_count": 3,
    "last_benchmark_dl_bps": 4200 * 1024 * 1024,  # 4.2 Gbps benchmark
    "recent_avg_speed_bps": 200 * 1024 * 1024,
    "reliability_score": 95.0,
    "live_rx_bps": 150 * 1024 * 1024,
    "live_tx_bps": 50 * 1024 * 1024,
}

node_eu_idle = {
    "id": "node_eu_02",
    "name": "EU-02",
    "status": "ONLINE",
    "disk_free_bytes": 350 * 1024 * 1024 * 1024,  # 350 GB free
    "effective_ram_bytes": 4096 * 1024 * 1024,
    "ram_used_bytes": 512 * 1024 * 1024,
    "active_jobs_count": 0,
    "last_benchmark_dl_bps": 3800 * 1024 * 1024,  # 3.8 Gbps benchmark
    "recent_avg_speed_bps": 360 * 1024 * 1024,   # 2.9 Gbps real throughput
    "reliability_score": 99.8,
    "live_rx_bps": 2 * 1024 * 1024,
    "live_tx_bps": 1 * 1024 * 1024,
}

node_offline = {
    "id": "node_us_03",
    "name": "US-03",
    "status": "OFFLINE",
    "disk_free_bytes": 500 * 1024 * 1024 * 1024,
    "active_jobs_count": 0,
}

# Test 1: Idle node with higher disk and real speed wins over busy node with higher benchmark
best, reason = select_best_node([node_eu_busy, node_eu_idle], expected_size=2 * 1024 * 1024 * 1024)
assert best is not None, "Expected a selected node"
assert best["name"] == "EU-02", f"Expected EU-02 to win, but got {best['name']}"
assert "EU-02" in reason, "Explanation must mention node name"
print(f"OK: Test 1 selected {best['name']} -> {reason}")

# Test 2: Offline node is excluded
best2, _ = select_best_node([node_offline])
assert best2 is None, "Offline node must not be selected"
print("OK: Test 2 offline node correctly excluded")

# Test 3: Insufficient disk exclusion
best3, reason3 = select_best_node([node_eu_busy], expected_size=10 * 1024 * 1024 * 1024)
assert best3 is None, "Node with insufficient disk must be rejected"
assert "insufficient disk" in reason3.lower(), f"Expected insufficient disk in reason, got: {reason3}"
print(f"OK: Test 3 low disk correctly rejected -> {reason3}")

# Test 4: Preferred node selection
best4, reason4 = select_best_node([node_eu_busy, node_eu_idle], preferred_node="EU-01", expected_size=1024*1024)
assert best4 is not None and best4["name"] == "EU-01", f"Expected preferred node EU-01, got {best4['name'] if best4 else None}"
print(f"OK: Test 4 preferred node honoured -> {reason4}")

print("All scheduler unit tests passed.")
EOF

assert_true "Scheduler tests completed successfully" test $? -eq 0

echo ""
echo "Scheduler test summary: $TEST_PASSED passed, $TEST_FAILED failed."
if [ "$TEST_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
