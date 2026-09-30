#!/usr/bin/env bash
# tests/test-cybernet-security.sh — Phase 3 CyberNet API Authentication & Access Control Tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"

log_header "Testing Phase 3 CyberNet API Authentication & Security Model"

PYTHONPATH="$REPO_DIR" python3 - << 'EOF'
import os
import tempfile
from pathlib import Path
from fastapi.testclient import TestClient

# Setup isolated temporary database for test
tmp_dir = tempfile.TemporaryDirectory()
os.environ["CYBERFLEET_DB_PATH"] = str(Path(tmp_dir.name) / "security_test.db")
os.environ["CYBERFLEET_SECRET"] = "super-secret-admin-key-12345"
os.environ["CYBERFLEET_ENROLLMENT_TOKEN"] = "admin-system-enroll-token"

from fleet.controller import app, DB
from fleet.cybernet import generate_wireguard_keypair

client = TestClient(app)

# 1. Verify Unauthenticated Rejection
r = client.get("/api/v1/net/devices")
assert r.status_code == 401, f"Expected 401 for unauthenticated devices list, got {r.status_code}"

r = client.get("/api/v1/net/summary")
assert r.status_code == 401, f"Expected 401 for unauthenticated summary, got {r.status_code}"

r = client.get("/api/v1/net/doctor")
assert r.status_code == 401, f"Expected 401 for unauthenticated doctor, got {r.status_code}"
print("PASS: Unauthenticated access rejected with HTTP 401")

# 2. Setup mock gateway node
priv_gw, pub_gw = generate_wireguard_keypair()
with DB.connection() as conn:
    conn.execute(
        "INSERT INTO nodes (id, name, secret_hash, status, enrolled_at, last_heartbeat) VALUES (?, ?, ?, 'ONLINE', 1000, 1000)",
        ("gw_node_1", "Gateway-1", "sec_hash")
    )
    conn.commit()

DB.set_gateway(
    node_id="gw_node_1",
    enabled=True,
    wireguard_enabled=True,
    wireguard_public_key=pub_gw,
    wireguard_private_key=priv_gw,
    ipv4_address="198.51.100.1",
)

# 3. Device Enrollment Authentication & Single-use Token Validation
_, pub_dev_a = generate_wireguard_keypair()
_, pub_dev_b = generate_wireguard_keypair()

# 3a. Rejection without enrollment token
r = client.post("/api/v1/net/devices/enroll", json={
    "name": "Phone-A",
    "public_key": pub_dev_a,
})
assert r.status_code == 401, f"Expected 401 without enrollment token, got {r.status_code}"

# 3b. Rejection with invalid token
r = client.post("/api/v1/net/devices/enroll", json={
    "name": "Phone-A",
    "public_key": pub_dev_a,
    "enrollment_token": "bogus_token",
})
assert r.status_code == 401, f"Expected 401 with bogus token, got {r.status_code}"

# 3c. Rejection with invalid public key
r = client.post("/api/v1/net/devices/enroll", json={
    "name": "Phone-A",
    "public_key": "not_a_valid_curve25519_key",
    "enrollment_token": "admin-system-enroll-token",
})
assert r.status_code == 400, f"Expected 400 with invalid public key, got {r.status_code}"

# 3d. Generate single-use pairing token via Admin API
admin_headers = {"Authorization": "Bearer super-secret-admin-key-12345"}
r = client.post("/api/v1/net/enroll-tokens", headers=admin_headers)
assert r.status_code == 200
pair_token = r.json()["token"]
assert pair_token.startswith("net_")

# 3e. Successful enrollment with pairing token
r = client.post("/api/v1/net/devices/enroll", json={
    "name": "Phone-A",
    "public_key": pub_dev_a,
    "enrollment_token": pair_token,
})
assert r.status_code == 200, f"Enrollment failed: {r.text}"
dev_a_id = r.json()["device_id"]
dev_a_token = r.json()["token"]
print("PASS: Device enrollment with valid pairing token succeeds")

# 3f. Token replay rejection: single-use pairing token must be consumed
r = client.post("/api/v1/net/devices/enroll", json={
    "name": "Phone-Replay",
    "public_key": pub_dev_b,
    "enrollment_token": pair_token,
})
assert r.status_code == 401, f"Expected 401 on reused single-use token, got {r.status_code}"
print("PASS: Single-use pairing token replay prevention verified")

# Enroll Device B using system token
r = client.post("/api/v1/net/devices/enroll", json={
    "name": "Phone-B",
    "public_key": pub_dev_b,
    "enrollment_token": "admin-system-enroll-token",
})
assert r.status_code == 200
dev_b_id = r.json()["device_id"]
dev_b_token = r.json()["token"]

# 4. Session Creation & Identity Verification
auth_a = {"Authorization": f"Bearer {dev_a_token}"}
auth_b = {"Authorization": f"Bearer {dev_b_token}"}

# 4a. Unauthenticated session creation rejected
r = client.post("/api/v1/net/session", json={"device_id": dev_a_id})
assert r.status_code == 401, f"Expected 401 for unauthenticated session create, got {r.status_code}"

# 4b. Identity spoofing prevention: Device A trying to create session for Device B
r = client.post("/api/v1/net/session", headers=auth_a, json={"device_id": dev_b_id})
assert r.status_code == 403, f"Expected 403 for mismatched device_id, got {r.status_code}"
print("PASS: Cross-device identity spoofing prevented (HTTP 403)")

# 4c. Valid session creation
r = client.post("/api/v1/net/session", headers=auth_a, json={
    "device_id": dev_a_id,
    "score_profile": "BALANCED",
})
assert r.status_code == 200, f"Session create failed: {r.text}"
sess_resp = r.json()
sess_id = sess_resp["session_id"]
assert sess_resp["gateway_id"] == "gw_node_1"
assert sess_resp["gateway_public_key"] == pub_gw
assert "${CLIENT_PRIVATE_KEY}" in sess_resp["wireguard_config"]
print("PASS: Valid session created with genuine keys and zero-knowledge template")

# 5. Cross-Device Hijacking Prevention
# 5a. Device B cannot switch Device A's session
r = client.post("/api/v1/net/session/switch", headers=auth_b, json={
    "session_id": sess_id,
    "target_gateway_id": "gw_node_1",
})
assert r.status_code == 403, f"Expected 403 when Device B switches Device A's session, got {r.status_code}"

# 5b. Device B cannot terminate Device A's session
r = client.delete(f"/api/v1/net/session/{sess_id}", headers=auth_b)
assert r.status_code == 403, f"Expected 403 when Device B terminates Device A's session, got {r.status_code}"

# 5c. Device B cannot read Device A's session stats
r = client.get(f"/api/v1/net/session/{sess_id}/stats", headers=auth_b)
assert r.status_code == 403, f"Expected 403 when Device B reads Device A's stats, got {r.status_code}"

# 5d. Device B cannot send heartbeat for Device A's session
r = client.post(f"/api/v1/net/session/{sess_id}/heartbeat", headers=auth_b, json={"bytes_rx": 100})
assert r.status_code == 403, f"Expected 403 when Device B sends heartbeat for Device A, got {r.status_code}"
print("PASS: All cross-device session hijacking attempts strictly blocked (HTTP 403)")

# 6. Legitimate Session Operations
r = client.post(f"/api/v1/net/session/{sess_id}/heartbeat", headers=auth_a, json={"bytes_rx": 1024, "bytes_tx": 2048})
assert r.status_code == 200

r = client.get(f"/api/v1/net/session/{sess_id}/stats", headers=auth_a)
assert r.status_code == 200
assert r.json()["bytes_rx"] == 1024

# 7. Device Revocation & Enforcement
r = client.post(f"/api/v1/net/devices/{dev_a_id}/revoke", headers=admin_headers)
assert r.status_code == 200

# Revoked device is blocked from API
r = client.post("/api/v1/net/session", headers=auth_a, json={"device_id": dev_a_id})
assert r.status_code == 403, f"Expected 403 for revoked device, got {r.status_code}"

r = client.post(f"/api/v1/net/session/{sess_id}/heartbeat", headers=auth_a, json={"bytes_rx": 100})
assert r.status_code == 403, f"Expected 403 for revoked device heartbeat, got {r.status_code}"
print("PASS: Revoked device access strictly denied (HTTP 403)")

tmp_dir.cleanup()
print("\nALL CYBERNET SECURITY TESTS PASSED PERFECTLY!")
EOF

log_ok "All Phase 3 CyberNet API Authentication tests passed successfully!"
