#!/usr/bin/env bash
# tests/test-jobs.sh — Automated tests for CyberVPS persistent job manager & watchdog
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

ORIG_PATH="$PATH"
MOCK_ROOT="$(mktemp -d /tmp/cybervps-test-jobs-XXXXXX)"
export HOME="$MOCK_ROOT"
export XDG_STATE_HOME="$MOCK_ROOT/.local/state"
export XDG_CONFIG_HOME="$MOCK_ROOT/.config"
export PATH="$ORIG_PATH:$MOCK_ROOT/.local/bin"

# shellcheck source=lib/jobs.sh
source "$REPO_DIR/lib/jobs.sh"

cleanup() {
    job_cancel "test-job-1" 2>/dev/null || true
    job_cancel "test-job-bg" 2>/dev/null || true
    rm -rf "$MOCK_ROOT"
}
trap cleanup EXIT

echo "=== Testing Background Job Execution ==="
job_run "test-job-1" "echo 'job start'; sleep 3; echo 'job finish'"
test -f "$XDG_STATE_HOME/cybervps/jobs/test-job-1.json"
test -f "$XDG_STATE_HOME/cybervps/jobs/test-job-1.pid"

if ! job_is_running "test-job-1"; then
    echo "Expected test-job-1 to be running"
    exit 1
fi
echo "✔ PASS: Job launched and running"

echo "=== Testing Job Listing & Status ==="
list_out="$(job_list)"
echo "$list_out" | grep "test-job-1" >/dev/null
status_out="$(job_status "test-job-1")"
echo "$status_out" | grep "RUNNING" >/dev/null
echo "✔ PASS: Job listed and status retrieved"

echo "=== Testing Job Logs ==="
logs_out=""
for _ in {1..20}; do
    logs_out="$(job_logs "test-job-1" 10)"
    if echo "$logs_out" | grep "job start" >/dev/null; then
        break
    fi
    sleep 0.1
done
echo "$logs_out" | grep "job start" >/dev/null
echo "✔ PASS: Job logs retrieved"

echo "=== Testing Job Cancellation ==="
job_cancel "test-job-1"
if job_is_running "test-job-1"; then
    echo "Expected test-job-1 to be cancelled"
    exit 1
fi
status_after="$(job_status "test-job-1")"
echo "$status_after" | grep "CANCELLED" >/dev/null
echo "✔ PASS: Job cancelled cleanly"

echo "=== Testing Service Watchdog ==="
# Register a mock dead service that is enabled
SERVICES_CONFIG_DIR="$XDG_CONFIG_HOME/cybervps/services"
mkdir -p "$SERVICES_CONFIG_DIR"
cat > "$SERVICES_CONFIG_DIR/mock-service.json" <<EOF
{
  "name": "mock-service",
  "command": "echo mock > /dev/null",
  "enabled": true,
  "restart": "on-failure",
  "crash_count": 0
}
EOF

watchdog_out="$(job_watchdog 2>&1 || true)"
echo "$watchdog_out" | grep -i "Watchdog" >/dev/null
echo "✔ PASS: Service watchdog supervision executed"

echo "=== Testing CLI Dispatcher ==="
handle_job_cli list >/dev/null
handle_job_cli help | grep -i "Persistent Job" >/dev/null
echo "✔ PASS: CLI dispatcher functional"

echo "ALL JOB & WATCHDOG TESTS PASSED"
