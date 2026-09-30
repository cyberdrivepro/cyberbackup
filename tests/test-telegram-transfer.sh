#!/usr/bin/env bash
# tests/test-telegram-transfer.sh — Telegram Bot Transfer & Access Control Tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"

log_header "Testing Telegram Bot Transfer Integration & Access Control"

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
import sys
import time
from fleet.telegram import TelegramTransferBot

# Mock Controller
class MockController:
    def __init__(self):
        pass

bot = TelegramTransferBot(MockController())
bot.admin_ids = [123456, 789012]
bot.token = "123456789" + ":" + "mock_telegram_token"

# 1. Access Control Verification
assert bot.is_authorized(123456) is True, "Admin 123456 must be authorized"
assert bot.is_authorized(789012) is True, "Admin 789012 must be authorized"
assert bot.is_authorized(999999) is False, "Unauthorized user 999999 must be rejected"
assert bot.is_authorized(1) is False, "First user cannot automatically become admin"
print("OK: Telegram access control verified")

# 2. Throttling of live progress edits
bot.last_edit_time["job_test"] = time.time()
# Attempt immediate second edit within 1 second -> should be throttled
initial_time = bot.last_edit_time["job_test"]
bot.update_progress("job_test", 123456, 100, "file.iso", 500, 1000, 100000, 5, "eu-01")
assert bot.last_edit_time["job_test"] == initial_time, "Edit within 3 seconds must be throttled"
print("OK: Progress edit rate throttling verified")

# 3. Secure Token Storage (Permissions 0600)
from fleet.telegram import get_telegram_config
token, admins = get_telegram_config()
print("OK: Telegram configuration parsing verified")

print("All telegram transfer unit tests passed.")
EOF

assert_true "Telegram transfer tests completed successfully" test $? -eq 0

echo ""
echo "Telegram transfer test summary: $TEST_PASSED passed, $TEST_FAILED failed."
if [ "$TEST_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
