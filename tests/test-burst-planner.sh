#!/usr/bin/env bash
# tests/test-burst-planner.sh — Phase 2 BURST Planner & Adaptive Scheduler Tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"

log_header "Testing Phase 2 BURST Planner & Adaptive Scheduler"

PYTHONPATH="$REPO_DIR" python3 - << 'EOF'
import sys
from fleet.models import JobMode, NodeRecord, ProbeResult
from fleet.burst import (
    calculate_adaptive_chunk_size,
    create_chunk_plan,
    evaluate_burst_eligibility,
    select_assembler_node,
)

# 1. Test Adaptive Chunk Sizing
sz_100m = 100 * 1024 * 1024
chunk_100m = calculate_adaptive_chunk_size(sz_100m, active_workers=3)
assert chunk_100m >= 8 * 1024 * 1024, f"Chunk size for 100MB with 3 workers must be >= 8MB, got {chunk_100m}"

sz_10g = 10 * 1024 * 1024 * 1024
chunk_10g = calculate_adaptive_chunk_size(sz_10g, active_workers=8)
assert chunk_10g <= 512 * 1024 * 1024, f"Chunk size must be <= 512MB, got {chunk_10g}"
assert chunk_10g >= 128 * 1024 * 1024, f"Large file chunk should scale up, got {chunk_10g}"
print("OK: Adaptive chunk sizing bounds verified")

# 2. Test Node Pool & Assembler Selection
node1 = NodeRecord(
    id="node_fast",
    name="VPS-Fast",
    status="ONLINE",
    is_drained=False,
    disk_free_bytes=100 * 1024 * 1024 * 1024,
    live_rx_bps=80000000.0,
    recent_avg_speed_bps=50000000.0,
    reliability_score=99.0
)
node2 = NodeRecord(
    id="node_slow",
    name="VPS-Slow",
    status="ONLINE",
    is_drained=False,
    disk_free_bytes=20 * 1024 * 1024 * 1024,
    live_rx_bps=60000000.0,
    recent_avg_speed_bps=40000000.0,
    reliability_score=95.0
)
node_drained = NodeRecord(
    id="node_drained",
    name="VPS-Drained",
    status="ONLINE",
    is_drained=True,
    disk_free_bytes=500 * 1024 * 1024 * 1024,
    live_rx_bps=100000000.0,
)

nodes = [node1, node2, node_drained]
assembler = select_assembler_node(nodes, expected_size=5 * 1024 * 1024 * 1024)
assert assembler is not None, "Must select an assembler"
assert assembler.id == "node_fast", f"Expected node_fast as assembler, got {assembler.id}"
assert not assembler.is_drained, "Assembler must not be a drained node"
print("OK: Assembler node selection verified")

# 3. Test AUTO Mode Heuristic Eligibility
probe_large_range = ProbeResult(
    valid=True,
    url="https://example.com/huge.iso",
    final_url="https://example.com/huge.iso",
    expected_size=1 * 1024 * 1024 * 1024,
    accept_ranges=True,
)
mode_res, reason = evaluate_burst_eligibility(probe_large_range, [node1, node2], JobMode.AUTO)
assert mode_res == "BURST", f"Large file with ranges and 2 nodes must select BURST, got {mode_res}"

# Small file -> SINGLE
probe_small = ProbeResult(
    valid=True,
    url="https://example.com/small.zip",
    final_url="https://example.com/small.zip",
    expected_size=10 * 1024 * 1024,
    accept_ranges=True,
)
mode_res_sm, reason_sm = evaluate_burst_eligibility(probe_small, [node1, node2], JobMode.AUTO)
assert mode_res_sm == "SINGLE", f"Small file must select SINGLE in AUTO mode, got {mode_res_sm}"

# No range support -> SINGLE
probe_no_range = ProbeResult(
    valid=True,
    url="https://example.com/stream",
    final_url="https://example.com/stream",
    expected_size=500 * 1024 * 1024,
    accept_ranges=False,
)
mode_res_nr, reason_nr = evaluate_burst_eligibility(probe_no_range, [node1, node2], JobMode.AUTO)
assert mode_res_nr == "SINGLE", f"No range support must fallback to SINGLE, got {mode_res_nr}"

# Explicit mode forced
mode_res_forced, _ = evaluate_burst_eligibility(probe_small, [node1, node2], JobMode.BURST)
assert mode_res_forced == "BURST", "Forced BURST mode must be honored"

mode_res_mirror, _ = evaluate_burst_eligibility(probe_small, [node1, node2], JobMode.MIRROR)
assert mode_res_mirror == "MIRROR", "Forced MIRROR mode must be honored"
print("OK: Mode evaluation heuristics verified")

# 4. Test Chunk Plan Slicing & Work Stealing Queue
file_bytes = 1000 * 1024 * 1024 # 1000 MB
active_workers = [node1, node2]
chunks = create_chunk_plan("job_test_123", file_bytes, active_workers, assembler_node_id="node_fast")
assert len(chunks) > 0, "Chunks must be planned"

# Verify non-overlapping contiguous coverage
prev_end = -1
total_covered = 0
for idx, c in enumerate(chunks):
    assert c.chunk_index == idx, f"Chunk index out of order: {c.chunk_index} vs {idx}"
    assert c.start_byte == prev_end + 1, f"Gap or overlap at chunk {idx}: start {c.start_byte} vs prev_end {prev_end}"
    assert c.end_byte >= c.start_byte, f"Invalid byte range in chunk {idx}"
    assert c.byte_length == (c.end_byte - c.start_byte + 1)
    total_covered += c.byte_length
    prev_end = c.end_byte

assert total_covered == file_bytes, f"Total chunk coverage {total_covered} does not match file size {file_bytes}"
assert prev_end == file_bytes - 1, f"Final byte {prev_end} does not reach end {file_bytes - 1}"

# Verify work stealing queue partitioning
assigned_count = sum(1 for c in chunks if c.node_id is not None)
pending_count = sum(1 for c in chunks if c.status.value == "PENDING" and c.node_id is None)
assert assigned_count > 0, "Initial batch must be assigned"
print(f"OK: Chunk plan verified ({len(chunks)} chunks, {assigned_count} assigned, {pending_count} in work-stealing queue)")

EOF

log_ok "All Phase 2 BURST Planner tests passed successfully!"
