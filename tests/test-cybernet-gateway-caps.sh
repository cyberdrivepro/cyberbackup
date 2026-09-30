#!/usr/bin/env bash
# tests/test-cybernet-gateway-caps.sh — Gateway Capability Detection & Truthful Provisioning Tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"

log_header "Testing Gateway Capability Detection & Truthful Provisioning"

PYTHONPATH="$REPO_DIR" python3 - << 'EOF'
import os
import tempfile
from pathlib import Path

from fleet.cybernet import detect_gateway_capabilities, validate_public_key
from fleet.database import FleetDatabase

# 1. Test capability detection in current environment
caps = detect_gateway_capabilities()
assert "wireguard_capable" in caps
assert "wireguard_status" in caps
assert "wireguard_status_detail" in caps
assert "userspace_fallback_ready" in caps
assert caps["userspace_fallback_ready"] is True
assert caps["wireguard_status"] in ("READY", "DEGRADED", "UNSUPPORTED")
print(f"PASS: Capability detection completed (WireGuard status: {caps['wireguard_status']}, Fallback: READY)")

# 2. Test truthful gateway provisioning in DB
with tempfile.TemporaryDirectory() as tmpdir:
    db = FleetDatabase(Path(tmpdir) / "test_caps.db")
    with db.connection() as conn:
        conn.execute("INSERT INTO nodes (id, name, secret_hash, status, enrolled_at, last_heartbeat) VALUES (?, ?, ?, 'ONLINE', 1000, 1000)",
                     ("node_1", "Node-1", "sec"))
        conn.commit()

    # Enable gateway via database method
    gw = db.set_gateway(
        node_id="node_1",
        enabled=True,
        wireguard_enabled=caps["wireguard_capable"],
        wireguard_status=caps["wireguard_status"],
        wireguard_status_detail=caps["wireguard_status_detail"],
        userspace_fallback_ready=True,
        wireguard_public_key="hSDwCYkwp1R0i33ctD73Wg2/Og0mOBr066SpjqqbTmo=",
        wireguard_private_key="priv==",
        ipv4_address="192.0.2.1",
    )

    saved_gw = db.get_gateway("node_1")
    assert saved_gw is not None
    assert saved_gw.wireguard_status == caps["wireguard_status"]
    assert saved_gw.wireguard_status_detail == caps["wireguard_status_detail"]
    assert saved_gw.userspace_fallback_ready is True
    assert validate_public_key(saved_gw.wireguard_public_key) is True
    print("PASS: Truthful capability persistence verified in database")

    # 3. Test token operations
    tok = db.create_enroll_token(ttl_seconds=10, created_by="test")
    assert tok.startswith("net_")
    assert db.validate_and_consume_enroll_token(tok) is True
    assert db.validate_and_consume_enroll_token(tok) is False # cannot consume twice
    print("PASS: Device enrollment token lifecycle verified")

EOF

# 4. Test CLI enroll-token and gateways status output
export PYTHONPATH="$REPO_DIR"
TEST_TMP=$(mktemp -d)
export CYBERFLEET_DB_PATH="$TEST_TMP/cli_test.db"

python3 -m fleet.cli net enroll-token create --ttl 600 > "$TEST_TMP/out.txt"
grep -q "Generated mobile device enrollment token" "$TEST_TMP/out.txt"
grep -q "net_" "$TEST_TMP/out.txt"
echo "PASS: CLI enroll-token create output verified"

python3 -m fleet.cli net enroll-token list > "$TEST_TMP/list.txt"
grep -q "VALID" "$TEST_TMP/list.txt"
grep -q "net_" "$TEST_TMP/list.txt"
echo "PASS: CLI enroll-token list output verified"

rm -rf "$TEST_TMP"

log_ok "All Gateway Capability and Truthful Provisioning tests passed successfully!"
