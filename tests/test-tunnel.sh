#!/usr/bin/env bash
# tests/test-tunnel.sh — Automated tests for CyberVPS Cloudflare tunnel integration
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

# shellcheck source=lib/tunnel.sh
source "$REPO_DIR/lib/tunnel.sh"

ORIG_PATH="$PATH"
MOCK_ROOT="$(mktemp -d /tmp/cybervps-test-tunnel-XXXXXX)"
export HOME="$MOCK_ROOT"
export XDG_CONFIG_HOME="$MOCK_ROOT/.config"
export XDG_STATE_HOME="$MOCK_ROOT/.local/state"
export PATH="$ORIG_PATH:$MOCK_ROOT/.local/bin"

cleanup() {
    tunnel_stop "test-mock-tunnel" 2>/dev/null || true
    rm -rf "$MOCK_ROOT"
}
trap cleanup EXIT

echo "=== Testing Tunnel Initial Stopped State ==="
! tunnel_is_running "test-mock-tunnel"
status_out="$(tunnel_status "test-mock-tunnel" || true)"
echo "$status_out" | grep -q "STOPPED"
echo "✔ PASS: Tunnel initial stopped state"

echo "=== Testing Tunnel Start & PID Tracking ==="
tunnel_init_dirs

# Mock cloudflared execution for reliable headless test
pid_file="$TUNNEL_STATE_DIR/test-mock-tunnel.pid"
meta_file="$TUNNEL_STATE_DIR/test-mock-tunnel.json"
log_file="$TUNNEL_LOGS_DIR/tunnel_test-mock-tunnel.log"

sleep 60 > "$log_file" 2>&1 &
mock_pid=$!
echo "$mock_pid" > "$pid_file"
process_record "$mock_pid" "$pid_file"

cat > "$meta_file" <<EOF
{
  "target": "test-mock-tunnel",
  "port": 7681,
  "pid": $mock_pid,
  "type": "quick_tunnel",
  "url": "https://test-mock-subdomain.trycloudflare.com",
  "started_at": "2026-09-28T02:00:00Z"
}
EOF

tunnel_is_running "test-mock-tunnel"
echo "✔ PASS: Tunnel process detection"

echo "=== Testing Tunnel Status & Metadata ==="
status_out="$(tunnel_status "test-mock-tunnel")"
echo "$status_out" | grep -q "RUNNING"
echo "$status_out" | grep -q "trycloudflare.com"
echo "✔ PASS: Tunnel status output & URL resolution"

echo "=== Testing Tunnel Logs ==="
echo "Mock log line 1" >> "$log_file"
echo "Mock log line 2" >> "$log_file"
logs_out="$(tunnel_logs "test-mock-tunnel" 5)"
echo "$logs_out" | grep -q "Mock log line 1"
echo "✔ PASS: Tunnel logs inspection"

echo "=== Testing Tunnel Stop ==="
tunnel_stop "test-mock-tunnel"
! tunnel_is_running "test-mock-tunnel"
echo "✔ PASS: Tunnel stop cleanly terminates process"

echo "All tunnel tests passed!"
exit 0
