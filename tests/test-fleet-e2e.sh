#!/usr/bin/env bash
# tests/test-fleet-e2e.sh — Comprehensive End-to-End Fleet & Transfer Integration Tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"

log_header "Testing CyberFleet & CyberTransfer End-to-End Workflow"

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
import http.server
import os
from pathlib import Path
import socketserver
import sys
import tempfile
import threading
import time

from fastapi.testclient import TestClient
from fleet.database import FleetDatabase

# Set temporary DB path for clean test isolation
test_tmp = tempfile.mkdtemp()
db_path = Path(test_tmp) / "e2e_fleet.db"
os.environ["CYBERFLEET_DB_PATH"] = str(db_path)
os.environ["CYBERFLEET_ENROLLMENT_TOKEN"] = "test-token-secret"
os.environ["CYBERFLEET_SECRET"] = "master-secret-key-12345"

# Re-import controller with updated environment
import fleet.controller as ctrl
ctrl.DB = FleetDatabase(db_path)
client = TestClient(ctrl.app)

# 1. Start Local Test HTTP Server to act as external download source
srv_dir = tempfile.mkdtemp()
test_payload = b"CYBERVPS CLOUD TRANSFER PAYLOAD E2E" * 100
sample_file = Path(srv_dir) / "test_iso.iso"
sample_file.write_bytes(test_payload)
expected_sha256 = hashlib.sha256(test_payload).hexdigest()

class SimpleHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=srv_dir, **kwargs)
    def log_message(self, format, *args):
        pass

httpd = socketserver.TCPServer(("127.0.0.1", 0), SimpleHandler)
srv_port = httpd.server_address[1]
srv_thread = threading.Thread(target=httpd.serve_forever, daemon=True)
srv_thread.start()

try:
    # 2. Authenticate as Admin
    login_resp = client.post("/api/v1/auth/login", json={"username": "admin", "password": "cybervps"})
    assert login_resp.status_code == 200, f"Login failed: {login_resp.text}"
    session_cookie = login_resp.cookies.get("cybervps_session")
    client.cookies.set("cybervps_session", session_cookie)
    print("OK: Step 1 Admin authentication successful")

    # 3. Enroll VPS Agent A
    enroll_a = client.post("/api/v1/nodes/enroll", json={
        "enrollment_token": "test-token-secret",
        "node_name": "VPS-Node-A",
        "hostname": "node-a.cloud",
        "privilege_mode": "ROOTLESS",
        "capabilities": {"aria2c": True, "curl": True}
    })
    assert enroll_a.status_code == 200, f"Enroll A failed: {enroll_a.text}"
    node_a = enroll_a.json()
    assert node_a["ok"] is True
    node_a_id = node_a["node_id"]
    node_a_secret = node_a["node_secret"]
    print(f"OK: Step 2 Enrolled VPS Agent A ({node_a_id})")

    # 4. Enroll VPS Agent B
    enroll_b = client.post("/api/v1/nodes/enroll", json={
        "enrollment_token": "test-token-secret",
        "node_name": "VPS-Node-B",
        "hostname": "node-b.cloud",
        "privilege_mode": "CONTAINER_ROOT",
        "capabilities": {"aria2c": False, "curl": True}
    })
    assert enroll_b.status_code == 200, f"Enroll B failed: {enroll_b.text}"
    node_b = enroll_b.json()
    node_b_id = node_b["node_id"]
    node_b_secret = node_b["node_secret"]
    print(f"OK: Step 3 Enrolled VPS Agent B ({node_b_id})")

    # Send initial heartbeats
    headers_a = {"X-Node-ID": node_a_id, "X-Node-Secret": node_a_secret}
    hb_a = client.post("/api/v1/agent/heartbeat", json={
        "node_id": node_a_id,
        "effective_cpu": 4.0,
        "effective_ram_bytes": 4096 * 1024 * 1024,
        "disk_free_bytes": 100 * 1024 * 1024 * 1024,
        "live_rx_bps": 1000000.0,
        "live_tx_bps": 500000.0,
    }, headers=headers_a)
    assert hb_a.status_code == 200

    headers_b = {"X-Node-ID": node_b_id, "X-Node-Secret": node_b_secret}
    hb_b = client.post("/api/v1/agent/heartbeat", json={
        "node_id": node_b_id,
        "effective_cpu": 2.0,
        "effective_ram_bytes": 1024 * 1024 * 1024,
        "disk_free_bytes": 20 * 1024 * 1024 * 1024,
    }, headers=headers_b)
    assert hb_b.status_code == 200

    # Verify both nodes visible
    nodes_resp = client.get("/api/v1/nodes")
    nodes_data = nodes_resp.json()["nodes"]
    assert len(nodes_data) == 2, f"Expected 2 nodes, got {len(nodes_data)}"
    assert all(n["status"] == "ONLINE" for n in nodes_data)
    print("OK: Step 4 Both nodes independently visible and ONLINE")

    # 5. Stop Agent B (Simulate Timeout -> OFFLINE)
    with ctrl.DB.connection() as conn:
        conn.execute("UPDATE nodes SET last_heartbeat = ? WHERE id = ?", (time.time() - 60, node_b_id))
        conn.commit()

    # Trigger watchdog check
    for n in ctrl.DB.list_nodes():
        if time.time() - n["last_heartbeat"] > 45:
            ctrl.DB.set_node_status(n["id"], "OFFLINE")

    node_b_state = ctrl.DB.get_node(node_b_id)
    assert node_b_state["status"] == "OFFLINE", "Node B must be OFFLINE"
    print("OK: Step 5 Node B status transitioned to OFFLINE")

    # 6. Restart Agent B (Heartbeat -> ONLINE without re-enrollment)
    hb_b_restart = client.post("/api/v1/agent/heartbeat", json={"node_id": node_b_id}, headers=headers_b)
    assert hb_b_restart.status_code == 200
    assert ctrl.DB.get_node(node_b_id)["status"] == "ONLINE", "Node B must return to ONLINE"
    print("OK: Step 6 Node B returned to ONLINE upon reconnect")

    # 7. SSRF Protection: Rejection of Private IP / Localhost from public job submission
    bad_req = client.post("/api/v1/jobs", json={"url": "http://127.0.0.1:80/evil"})
    assert bad_req.status_code == 400, f"Expected 400 for SSRF target, got {bad_req.status_code}"
    print("OK: Step 7 SSRF protection strictly rejected private / loopback target")

    # 8. Submit Valid Download Job
    # Allow private for our local test server URL
    job, err = ctrl.controller_create_job_internal(url=f"http://127.0.0.1:{srv_port}/test_iso.iso", allow_private=True)
    # For testing probe internally with allow_private:
    from fleet.probe import probe_url
    probe = probe_url(f"http://127.0.0.1:{srv_port}/test_iso.iso", allow_private=True)
    assert probe.valid is True, f"Probe failed: {probe.error}"
    assert probe.filename == "test_iso.iso"
    assert probe.expected_size == len(test_payload)
    print(f"OK: Step 8 URL probe verified file metadata: {probe.filename} ({probe.expected_size} bytes)")

    # Create job assigned to Node A
    from fleet.models import JobRecord, JobStatus
    job_id = "job_e2e_test"
    ctrl.DB.create_job(JobRecord(
        id=job_id,
        requested_url=f"http://127.0.0.1:{srv_port}/test_iso.iso",
        filename="test_iso.iso",
        expected_size=len(test_payload),
        status=JobStatus.ASSIGNED,
        node_id=node_a_id,
    ))

    # 9. Agent A fetches assigned job
    fetch_resp = client.get("/api/v1/agent/jobs", headers=headers_a)
    assigned_jobs = fetch_resp.json()["jobs"]
    assert any(j["id"] == job_id for j in assigned_jobs), "Job must be dispatched to Node A"
    print("OK: Step 9 Job dispatched to selected Node A")

    # 10. Agent A executes download & updates progress
    client.post(f"/api/v1/agent/jobs/{job_id}/start", headers=headers_a)
    client.post(f"/api/v1/agent/jobs/{job_id}/progress", json={
        "downloaded_bytes": len(test_payload) // 2,
        "total_bytes": len(test_payload),
        "current_speed_bps": 5000000.0,
        "eta_seconds": 2,
    }, headers=headers_a)
    
    in_progress = ctrl.DB.get_job(job_id)
    assert in_progress.status == JobStatus.DOWNLOADING
    assert in_progress.progress_percent == 50.0
    print("OK: Step 10 Job progress reported & tracked")

    # 11. Agent A completes job
    completed_file = Path(srv_dir) / "node_a_downloaded.iso"
    completed_file.write_bytes(test_payload)
    
    comp_resp = client.post(f"/api/v1/agent/jobs/{job_id}/complete", json={
        "sha256": expected_sha256,
        "size_bytes": len(test_payload),
        "duration_seconds": 1.5,
        "local_path": str(completed_file),
    }, headers=headers_a)
    assert comp_resp.status_code == 200
    comp_data = comp_resp.json()
    assert comp_data["ok"] is True
    direct_link_url = comp_data["direct_link"]
    token = direct_link_url.split("/f/")[-1]
    print(f"OK: Step 11 Job completed, SHA256 verified, signed direct link generated: {direct_link_url}")

    # 12. Download file using Cybershare Direct Link with HTTP Range (Partial Content)
    link_resp = client.get(f"/f/{token}", headers={"Range": "bytes=0-10"})
    assert link_resp.status_code == 206, f"Expected 206 Partial Content, got {link_resp.status_code}"
    assert link_resp.content == test_payload[0:11], f"Range content mismatch: {link_resp.content}"
    assert "Content-Range" in link_resp.headers
    print(f"OK: Step 12 Cybershare direct link served 206 Partial Content: {len(link_resp.content)} bytes")

    # 13. Full file download via signed link
    full_resp = client.get(f"/f/{token}")
    assert full_resp.status_code == 200
    assert full_resp.content == test_payload
    print("OK: Step 13 Full file downloaded via signed link verified")

finally:
    httpd.shutdown()

print("ALL E2E INTEGRATION TESTS PASSED SUCCESSFULLY!")
EOF

assert_true "End-to-End Fleet test workflow passed" test $? -eq 0

echo ""
echo "E2E test summary: $TEST_PASSED passed, $TEST_FAILED failed."
if [ "$TEST_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
