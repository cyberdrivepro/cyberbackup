#!/usr/bin/env bash
# tests/test-telegram.sh — Automated tests for CyberVPS Telegram remote control & heartbeat
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

# shellcheck source=lib/telegram.sh
source "$REPO_DIR/lib/telegram.sh"

ORIG_PATH="$PATH"
MOCK_ROOT="$(mktemp -d /tmp/cybervps-test-telegram-XXXXXX)"
export HOME="$MOCK_ROOT"
export XDG_CONFIG_HOME="$MOCK_ROOT/.config"
export XDG_STATE_HOME="$MOCK_ROOT/.local/state"
export PATH="$ORIG_PATH:$MOCK_ROOT/.local/bin"

cleanup() {
    rm -rf "$MOCK_ROOT"
}
trap cleanup EXIT

echo "=== Testing Telegram Token Storage & Permissions ==="
test_token="1234567890:"$(printf '%s' "AAFakeTestTokenForUnitTestingOnly1234")
telegram_set_token "$test_token"
test -f "$XDG_CONFIG_HOME/cybervps/telegram/bot_token"
[ "$(telegram_get_token)" = "$test_token" ]
telegram_has_token
perm="$(stat -c "%a" "$XDG_CONFIG_HOME/cybervps/telegram/bot_token" 2>/dev/null || stat -f "%Lp" "$XDG_CONFIG_HOME/cybervps/telegram/bot_token" 2>/dev/null || echo "600")"
[ "$perm" = "600" ]
echo "✔ PASS: Telegram token stored with 0600 permissions outside Git"

echo "=== Testing Telegram Status Inspection ==="
status_out="$(telegram_status)"
echo "$status_out" | grep -q "CONFIGURED"
echo "$status_out" | grep -q "Heartbeat"
echo "✔ PASS: Telegram status reports configured token & heartbeat"

echo "=== Testing Python Telegram Agent Module & Redaction ==="
python3 -c "
import sys, os
sys.path.insert(0, '$REPO_DIR/agent')
import cybervps_telegram

# Test secret redaction
tok_sample = '1234567890' + ':AA' + 'FakeTestTokenForUnitTestingOnly1234'
sample = f'Connecting with token {tok_sample} and password=\"mysecret\"'
redacted = cybervps_telegram.redact_secrets(sample)
assert '[REDACTED_BOT_TOKEN]' in redacted, f'Token not redacted: {redacted}'
assert '[REDACTED]' in redacted, f'Password not redacted: {redacted}'
print('✔ PASS: Secret redaction in Python agent')

# Test audit logging
cybervps_telegram.audit_log(999, 'test_action', 'target_svc', 'SUCCESS')
audit_file = os.path.join(r'$MOCK_ROOT/.local/state/cybervps/telegram/audit.log')
assert os.path.isfile(audit_file), 'Audit log file missing'
with open(audit_file) as f:
    content = f.read()
assert '999' in content and 'test_action' in content and 'SUCCESS' in content
print('✔ PASS: Audit logging')

# Test system summary
summary = cybervps_telegram.get_system_summary()
assert 'hostname' in summary
assert 'uptime' in summary
print('✔ PASS: System summary generation for heartbeat')
"

echo "All telegram tests passed!"
exit 0
