#!/usr/bin/env bash
# tests/test-cybernet-failover.sh — Phase 3 CyberNet Automatic Gateway Failover Tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"

log_header "Testing Phase 3 CyberNet Automatic Gateway Failover"

PYTHONPATH="$REPO_DIR" python3 - << 'EOF'
import hashlib
from pathlib import Path
import tempfile
import time

from fleet.database import FleetDatabase
from fleet.cybernet import select_best_gateways
from fleet.models import CyberNetScoreProfile, NodeRecord, NodeStatus

with tempfile.TemporaryDirectory() as tmpdir:
    db_path = Path(tmpdir) / "test_failover.db"
    db = FleetDatabase(db_path)

    # Setup Nodes & Gateways
    with db.connection() as conn:
        conn.execute("INSERT INTO nodes (id, name, secret_hash, status, enrolled_at, last_heartbeat) VALUES (?, ?, ?, ?, ?, ?)",
                     ("gw_primary", "NL-04", "sec", "ONLINE", time.time(), time.time()))
        conn.execute("INSERT INTO nodes (id, name, secret_hash, status, enrolled_at, last_heartbeat) VALUES (?, ?, ?, ?, ?, ?)",
                     ("gw_backup", "DE-01", "sec", "ONLINE", time.time(), time.time()))
        conn.commit()

    db.set_gateway(node_id="gw_primary", enabled=True, latency_ms=44.0, ipv4_address="192.0.2.4", region="NL")
    db.set_gateway(node_id="gw_backup", enabled=True, latency_ms=52.0, ipv4_address="192.0.2.1", region="DE")

    # Enroll device
    dev = db.enroll_device("dev_01", "Phone", "android", "Android 15", "pubkey", "tokenhash")

    # 1. Connect phone to primary gateway
    sess1 = db.create_session("sess_primary", dev.id, "gw_primary", "WIREGUARD", "10.66.0.2")
    assert sess1.gateway_node_id == "gw_primary"
    assert sess1.status.value == "ACTIVE"
    print("OK: Initial connection to primary gateway NL-04 established")

    # 2. Simulate Gateway A failing / going OFFLINE
    db.set_node_status("gw_primary", NodeStatus.OFFLINE)
    node_a = NodeRecord(**db.get_node("gw_primary"))
    assert node_a.status == NodeStatus.OFFLINE
    print("OK: Primary gateway marked OFFLINE (heartbeat lost)")

    # 3. Automatic failover selection
    gateways = db.list_gateways(only_enabled=True)
    nodes_map = {n["id"]: NodeRecord(**n) for n in db.list_nodes()}
    best_gw, backups = select_best_gateways(gateways, nodes_map, CyberNetScoreProfile.BALANCED)
    
    assert best_gw is not None
    assert best_gw.node_id == "gw_backup", f"Failover must select healthy DE-01, got {best_gw.node_id}"
    print("OK: Failover engine automatically selected backup gateway DE-01")

    # 4. Perform session switch
    db.terminate_session("sess_primary", disconnect_reason="GATEWAY_LOST")
    sess2 = db.create_session("sess_backup", dev.id, best_gw.node_id, "WIREGUARD", "10.66.0.2")

    sess1_after = db.get_session("sess_primary")
    assert sess1_after.status.value == "TERMINATED"
    assert sess1_after.disconnect_reason == "GATEWAY_LOST"

    sess2_active = db.get_active_session_for_device(dev.id)
    assert sess2_active.session_id == "sess_backup"
    assert sess2_active.gateway_node_id == "gw_backup"
    print("OK: Session migrated seamlessly to backup gateway without device re-enrollment")

EOF

log_ok "All Phase 3 CyberNet Failover tests passed successfully!"
