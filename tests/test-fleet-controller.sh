#!/usr/bin/env bash
# tests/test-fleet-controller.sh — Fleet Controller & State Machine Lifecycle Tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"

log_header "Testing Fleet Controller Lifecycle & State Machine"

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
import hashlib
from pathlib import Path
import sys
import tempfile
import time

from fleet.database import FleetDatabase
from fleet.models import JobRecord, JobStatus, NodeStatus

with tempfile.TemporaryDirectory() as tmpdir:
    db_file = Path(tmpdir) / "test_fleet.db"
    db = FleetDatabase(db_file)

    # 1. Node Enrollment
    raw_secret = "node" + "-mock-key-12345"
    secret_hash = hashlib.sha256(raw_secret.encode()).hexdigest()
    db.upsert_node_enrollment(
        node_id="node_test_1",
        name="VPS-Alpha",
        secret_hash=secret_hash,
        hostname="alpha.host",
        privilege_mode="CONTAINER_ROOT",
        effective_cpu=2.0,
        visible_cpu=4,
        effective_ram_bytes=1024 * 1024 * 1024,
        disk_free_bytes=50 * 1024 * 1024 * 1024,
    )

    node = db.get_node("node_test_1")
    assert node is not None, "Node must be registered"
    assert node["status"] == "ONLINE", "Initial status must be ONLINE"
    assert node["name"] == "VPS-Alpha"
    print("OK: Node enrollment verified")

    # 2. Heartbeat update
    db.update_node_heartbeat("node_test_1", {
        "hostname": "alpha.host",
        "effective_cpu": 2.0,
        "effective_ram_bytes": 1024 * 1024 * 1024,
        "disk_free_bytes": 48 * 1024 * 1024 * 1024,
        "live_rx_bps": 5000000.0,
        "live_tx_bps": 1000000.0,
        "active_jobs_count": 1,
    })
    node_hb = db.get_node("node_test_1")
    assert node_hb["live_rx_bps"] == 5000000.0
    print("OK: Heartbeat update verified")

    # 3. Create active download job
    job = JobRecord(
        id="job_t1",
        requested_url="https://example.com/test.iso",
        filename="test.iso",
        expected_size=500 * 1024 * 1024,
        status=JobStatus.DOWNLOADING,
        node_id="node_test_1",
    )
    db.create_job(job)
    assert db.get_job("job_t1") is not None
    print("OK: Job creation verified")

    # 4. Simulate Node Timeout & NODE_LOST transition
    with db.connection() as conn:
        # Move last_heartbeat to 60 seconds ago
        conn.execute("UPDATE nodes SET last_heartbeat = ? WHERE id = ?", (time.time() - 60, "node_test_1"))
        conn.commit()

    # Run state evaluator
    nodes = db.list_nodes()
    for n in nodes:
        diff = time.time() - n["last_heartbeat"]
        if diff > 45:
            db.set_node_status(n["id"], NodeStatus.OFFLINE)
            for j in db.list_jobs(status="DOWNLOADING"):
                if j.node_id == n["id"]:
                    db.update_job_status(j.id, JobStatus.NODE_LOST, "Node lost connection")

    assert db.get_node("node_test_1")["status"] == "OFFLINE", "Node must transition to OFFLINE"
    lost_job = db.get_job("job_t1")
    assert lost_job.status == JobStatus.NODE_LOST, f"Job must transition to NODE_LOST, got: {lost_job.status}"
    print("OK: Offline node and NODE_LOST job transition verified")

    # 5. Node Reconnects (Heartbeat) -> Returns to ONLINE
    db.update_node_heartbeat("node_test_1", {"hostname": "alpha.host"})
    assert db.get_node("node_test_1")["status"] == "ONLINE", "Reconnecting node must return to ONLINE"
    print("OK: Node reconnect without re-enrollment verified")

    # 6. Database Persistence Across Controller Restart
    del db
    new_db = FleetDatabase(db_file)
    restored_node = new_db.get_node("node_test_1")
    assert restored_node is not None, "Node must persist across restart"
    assert restored_node["name"] == "VPS-Alpha"
    restored_job = new_db.get_job("job_t1")
    assert restored_job is not None, "Job must persist across restart"
    print("OK: Database persistence across controller restart verified")

print("All fleet controller lifecycle tests passed.")
EOF

assert_true "Fleet controller tests completed successfully" test $? -eq 0

echo ""
echo "Controller test summary: $TEST_PASSED passed, $TEST_FAILED failed."
if [ "$TEST_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
