#!/usr/bin/env bash
# tests/test-cybernet-scoring.sh — Phase 3 CyberNet Multi-Profile Scoring Tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"

log_header "Testing Phase 3 CyberNet Multi-Profile Scoring & Node Selection"

PYTHONPATH="$REPO_DIR" python3 - << 'EOF'
from fleet.cybernet import calculate_gateway_score, select_best_gateways
from fleet.models import CyberNetGatewayInfo, CyberNetScoreProfile, NodeRecord, NodeStatus

# Setup mock nodes
node_de = NodeRecord(
    id="node_de_01",
    name="DE-01",
    effective_ram_bytes=2 * 1024 * 1024 * 1024,
    ram_used_bytes=512 * 1024 * 1024,
    effective_cpu=4.0,
    last_benchmark_dl_bps=4_200_000_000.0,
    status=NodeStatus.ONLINE,
)
gw_de = CyberNetGatewayInfo(
    node_id="node_de_01",
    latency_ms=52.0,
    packet_loss=0.1,
    active_sessions=10,
    ipv4_address="192.0.2.1",
    region="DE",
)

node_nl = NodeRecord(
    id="node_nl_04",
    name="NL-04",
    effective_ram_bytes=4 * 1024 * 1024 * 1024,
    ram_used_bytes=512 * 1024 * 1024,
    effective_cpu=8.0,
    last_benchmark_dl_bps=3_500_000_000.0,
    status=NodeStatus.ONLINE,
)
gw_nl = CyberNetGatewayInfo(
    node_id="node_nl_04",
    latency_ms=44.0, # Lower latency than DE
    packet_loss=0.0,
    active_sessions=2,  # Low sessions
    ipv4_address="192.0.2.4",
    region="NL",
)

node_us = NodeRecord(
    id="node_us_01",
    name="US-01",
    effective_ram_bytes=8 * 1024 * 1024 * 1024,
    ram_used_bytes=1024 * 1024 * 1024,
    effective_cpu=16.0,
    last_benchmark_dl_bps=8_000_000_000.0, # High throughput, high latency
    status=NodeStatus.ONLINE,
)
gw_us = CyberNetGatewayInfo(
    node_id="node_us_01",
    latency_ms=190.0,
    packet_loss=0.5,
    active_sessions=1,
    ipv4_address="192.0.2.10",
    region="US",
)

# Constrained low-RAM node (~60MB free RAM)
node_low_ram = NodeRecord(
    id="node_low_ram",
    name="TINY-01",
    effective_ram_bytes=512 * 1024 * 1024,
    ram_used_bytes=460 * 1024 * 1024,
    effective_cpu=1.0,
    status=NodeStatus.ONLINE,
)
gw_low_ram = CyberNetGatewayInfo(
    node_id="node_low_ram",
    latency_ms=30.0,
    ipv4_address="192.0.2.20",
    region="NL",
)

# 1. Test BALANCED profile: NL-04 should score higher than US-01 for mobile browsing
score_de_bal = calculate_gateway_score(gw_de, node_de, CyberNetScoreProfile.BALANCED)
score_nl_bal = calculate_gateway_score(gw_nl, node_nl, CyberNetScoreProfile.BALANCED)
score_us_bal = calculate_gateway_score(gw_us, node_us, CyberNetScoreProfile.BALANCED)

assert score_nl_bal > score_us_bal, f"NL-04 ({score_nl_bal}) should beat high-latency US-01 ({score_us_bal}) on BALANCED"
print(f"OK: BALANCED scoring verified (NL: {score_nl_bal}, DE: {score_de_bal}, US: {score_us_bal})")

# 2. Test LOW_LATENCY profile: NL-04 beats DE-01 and US-01
score_nl_lat = calculate_gateway_score(gw_nl, node_nl, CyberNetScoreProfile.LOW_LATENCY)
score_us_lat = calculate_gateway_score(gw_us, node_us, CyberNetScoreProfile.LOW_LATENCY)
assert score_nl_lat > score_us_lat + 20, "Low latency profile must heavily penalize 190ms US node"
print(f"OK: LOW_LATENCY profile verified (NL: {score_nl_lat}, US: {score_us_lat})")

# 3. Test MAX_THROUGHPUT profile: US-01 (8Gbps) wins
score_us_thru = calculate_gateway_score(gw_us, node_us, CyberNetScoreProfile.MAX_THROUGHPUT)
score_nl_thru = calculate_gateway_score(gw_nl, node_nl, CyberNetScoreProfile.MAX_THROUGHPUT)
assert score_us_thru > score_nl_thru, f"US 8Gbps node ({score_us_thru}) should win MAX_THROUGHPUT over NL 3.5Gbps ({score_nl_thru})"
print(f"OK: MAX_THROUGHPUT profile verified (US: {score_us_thru}, NL: {score_nl_thru})")

# 4. Test Low RAM protection: severely penalizes OOM-risk nodes
score_low = calculate_gateway_score(gw_low_ram, node_low_ram, CyberNetScoreProfile.BALANCED)
assert score_low <= 5.0, f"Constrained RAM node must be penalized (<5.0), got {score_low}"
print(f"OK: Low RAM node protection verified ({score_low})")

# 5. Test Best Gateway Selection & Ordered Backups
nodes_map = {n.id: n for n in [node_de, node_nl, node_us, node_low_ram]}
primary, backups = select_best_gateways(
    gateways=[gw_de, gw_nl, gw_us, gw_low_ram],
    nodes_by_id=nodes_map,
    profile=CyberNetScoreProfile.BALANCED,
    limit=2,
)
assert primary is not None, "Primary gateway must be chosen"
assert primary.node_id == "node_nl_04", f"Expected NL-04 as primary, got {primary.node_id}"
assert len(backups) == 2, f"Expected 2 backups, got {len(backups)}"
print(f"OK: Gateway selection and ordered failover backups verified (Primary: {primary.node_id}, Backups: {[b.node_id for b in backups]})")

EOF

log_ok "All Phase 3 CyberNet Scoring tests passed successfully!"
