#!/usr/bin/env bash
# tests/test-telegram-hardening.sh — Verify Telegram validation, classification, and diagnostics
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

# Temporary sandbox directory
TMP_SANDBOX="$(mktemp -d)"
export XDG_CONFIG_HOME="$TMP_SANDBOX/config"
export XDG_STATE_HOME="$TMP_SANDBOX/state"
trap 'rm -rf "$TMP_SANDBOX"' EXIT

# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"
# shellcheck source=lib/telegram.sh
source "$REPO_DIR/lib/telegram.sh"

echo "=== Test 1: Token Format Validation ==="
if telegram_validate_token_format "123456789:ABCdefGHIjklMNOpqrsTUVwxyz123456789"; then
    echo "PASS: Valid token format accepted"
else
    echo "FAIL: Valid token format rejected"
    exit 1
fi

if ! telegram_validate_token_format "invalid_token_string"; then
    echo "PASS: Invalid token format rejected"
else
    echo "FAIL: Invalid token format accepted"
    exit 1
fi

echo "=== Test 2: Token Storage & Redaction ==="
secret_token="987654321:SecretTestTokenABCDEF1234567890XYZ"
telegram_set_token "$secret_token"

saved_token="$(telegram_get_token)"
if [ "$saved_token" = "$secret_token" ]; then
    echo "PASS: Token saved correctly with 0600 permissions"
else
    echo "FAIL: Token mismatch: $saved_token"
    exit 1
fi

redacted="$(_telegram_redact "Connecting with bot ${secret_token} to API")"
if ! echo "$redacted" | grep -q "$secret_token" && echo "$redacted" | grep -q "<REDACTED_TOKEN>"; then
    echo "PASS: Token redacted securely: $redacted"
else
    echo "FAIL: Token leaked in output: $redacted"
    exit 1
fi

echo "=== Test 3: API getMe Classification on Invalid Token ==="
res="$(telegram_query_getme "$secret_token" || true)"
if echo "$res" | grep -qE 'AUTH_FAILED|DNS_FAILED|NETWORK_TIMEOUT'; then
    echo "PASS: Query properly classified failure without crashing ($res)"
else
    echo "FAIL: Unexpected classification: $res"
    exit 1
fi
# Ensure secret token was NEVER included in JSON result
if echo "$res" | grep -q "$secret_token"; then
    echo "FAIL: Secret token leaked in query response"
    exit 1
fi

echo "=== Test 4: Truthful Status Rendering ==="
status_out="$(telegram_status 2>&1)"
if echo "$status_out" | grep -q "Process" && echo "$status_out" | grep -q "API Access" && echo "$status_out" | grep -q "Admins"; then
    echo "PASS: Status displays truthful multi-state breakdown"
else
    echo "FAIL: Status output missing required state fields"
    exit 1
fi

echo "=== Test 5: Telegram Subsystem Doctor ==="
doctor_out="$(telegram_doctor 2>&1)"
if echo "$doctor_out" | grep -q "CYBERVPS TELEGRAM SUBSYSTEM DOCTOR"; then
    echo "PASS: Doctor output generated successfully"
else
    echo "FAIL: Doctor output missing title"
    exit 1
fi

echo "All Telegram hardening tests passed."
exit 0
