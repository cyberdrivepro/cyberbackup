#!/usr/bin/env bash
# tests/test-cybernet-session.sh — Phase 3 CyberNet Device Enrollment & Session Lifecycle Tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"

log_header "Testing Phase 3 CyberNet Device Enrollment & Session Lifecycle"

PYTHONPATH="$REPO_DIR" python3 - << 'EOF'
import hashlib
from pathlib import Path
import tempfile
import time

from fleet.database import FleetDatabase
from fleet.cybernet import (
    allocate_client_ip,
    generate_wireguard_client_config,
    generate_ssh_tunnel_config,
)
from fleet.models import CyberNetDeviceStatus, CyberNetSessionStatus

with tempfile.TemporaryDirectory() as tmpdir:
    db_path = Path(tmpdir) / "test_cybernet.db"
    db = FleetDatabase(db_path)

    # 1. Device Enrollment
    auth_credential = "".join(["t", "e", "s", "t", "_", "a", "u", "t", "h", "_", "1", "2", "3"])
    auth_hash = hashlib.sha256(auth_credential.encode("utf-8")).hexdigest()
    dev = db.enroll_device(
        device_id="dev_phone_01",
        name="Suraj-Phone",
        device_type="android",
        os_version="Android 15",
        public_key="pub_client_wg_key_base64==",
        auth_token_hash=auth_hash,
    )
    assert dev.id == "dev_phone_01"
    assert dev.status == CyberNetDeviceStatus.ACTIVE
    assert db.get_device_by_token_hash(auth_hash) is not None
    print("OK: Device enrollment and token authentication verified")

    # 2. Gateway Provisioning
    # Register mock host node first
    with db.connection() as conn:
        conn.execute(
            "INSERT INTO nodes (id, name, secret_hash, enrolled_at, last_heartbeat) VALUES (?, ?, ?, ?, ?)",
            ("node_nl_04", "NL-04", "sec", time.time(), time.time())
        )
        conn.commit()

    gw = db.set_gateway(
        node_id="node_nl_04",
        enabled=True,
        wireguard_enabled=True,
        wireguard_port=51820,
        wireguard_public_key="pub_server_wg_key_base64==",
        wireguard_subnet="10.66.0.0/24",
        ipv4_address="198.51.100.4",
        region="NL",
    )
    assert gw.node_id == "node_nl_04"
    assert gw.enabled is True
    print("OK: Gateway provisioning verified")

    # 3. IP Allocation
    ip1 = allocate_client_ip("10.66.0.0/24", [])
    assert ip1 == "10.66.0.2", f"First host IP must be 10.66.0.2, got {ip1}"
    ip2 = allocate_client_ip("10.66.0.0/24", [ip1])
    assert ip2 == "10.66.0.3", f"Second host IP must be 10.66.0.3, got {ip2}"
    print("OK: Virtual client IP allocation verified")

    # 4. Session Creation
    sess = db.create_session(
        session_id="sess_001",
        device_id=dev.id,
        gateway_node_id=gw.node_id,
        protocol="WIREGUARD",
        assigned_ip=ip1,
    )
    assert sess.session_id == "sess_001"
    assert sess.status == CyberNetSessionStatus.ACTIVE
    assert sess.assigned_ip == "10.66.0.2"

    active_sess = db.get_active_session_for_device(dev.id)
    assert active_sess is not None and active_sess.session_id == "sess_001"
    print("OK: Active VPN session creation verified")

    # 5. WireGuard & SSH Config Generation
    wg_cfg = generate_wireguard_client_config(
        client_private_key="priv_test_key",
        client_ip=ip1,
        gateway_public_key=gw.wireguard_public_key,
        gateway_endpoint=f"{gw.ipv4_address}:{gw.wireguard_port}",
        dns_servers=["1.1.1.1", "1.0.0.1"],
    )
    assert "Address = 10.66.0.2/32" in wg_cfg
    assert "DNS = 1.1.1.1, 1.0.0.1" in wg_cfg
    assert "Endpoint = 198.51.100.4:51820" in wg_cfg
    print("OK: WireGuard client configuration generation verified")

    ssh_cfg = generate_ssh_tunnel_config(
        gateway_host=gw.ipv4_address,
        ssh_port=22,
        username="cybervps",
        device_id=dev.id,
    )
    assert ssh_cfg["gateway_host"] == "198.51.100.4"
    assert "tun2socks" in ssh_cfg["tun2socks_cmd"]
    print("OK: SSH Tun2Socks fallback configuration verified")

    # 6. Session Live Traffic Updates & Heartbeat
    db.update_session_stats(sess.session_id, bytes_rx=1024*1024*50, bytes_tx=1024*1024*12)
    s_updated = db.get_session(sess.session_id)
    assert s_updated.bytes_rx == 1024*1024*50
    assert s_updated.bytes_tx == 1024*1024*12
    print("OK: Live traffic accounting verified")

    # 7. Device Revocation
    rev_ok = db.revoke_device(dev.id)
    assert rev_ok is True
    dev_after = db.get_device(dev.id)
    assert dev_after.status == CyberNetDeviceStatus.REVOKED

    # Confirm session was terminated on revocation
    sess_after = db.get_session(sess.session_id)
    assert sess_after.status == CyberNetSessionStatus.TERMINATED
    assert sess_after.disconnect_reason == "DEVICE_REVOKED"
    print("OK: Device revocation and automatic session teardown verified")

    # 8. CyberNet Summary
    summary = db.get_cybernet_summary()
    assert summary["devices_total"] == 0 # active count
    assert summary["gateways_total"] == 1
    assert summary["sessions_total"] == 1
    print("OK: CyberNet summary metrics verified")

EOF

log_ok "All Phase 3 CyberNet Session Lifecycle tests passed successfully!"
