#!/usr/bin/env bash
# tests/test-ssrf.sh — Strict SSRF Protection Unit & Integration Tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"

log_header "Testing SSRF Protection Engine"

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

assert_false() {
    local msg="$1"
    shift
    if "$@"; then
        log_error "FAIL: $msg (expected failure)"
        TEST_FAILED=$((TEST_FAILED + 1))
    else
        log_ok "PASS: $msg"
        TEST_PASSED=$((TEST_PASSED + 1))
    fi
}

PYTHONPATH="$REPO_DIR" python3 - << 'EOF'
import sys
from fleet.ssrf import validate_url, is_ip_disallowed
import ipaddress

# 1. Direct Loopback & Private IPs
bad_urls = [
    "http://127.0.0.1/secret",
    "http://127.0.0.2:8080/admin",
    "http://localhost/status",
    "http://[::1]/metrics",
    "http://10.0.0.1/internal",
    "http://192.168.1.100/router",
    "http://172.16.5.4/admin",
    "http://169.254.169.254/latest/meta-data/",
    "http://100.100.100.200/latest/meta-data/",
    "file:///etc/passwd",
    "ftp://ftp.example.com/file",
    "gopher://evil.com/",
    "data:text/plain;base64,SGVsbG8=",
    "http://user:pass@example.com/test",
    "http://example.com:22/ssh",
    "http://example.com:6379/redis",
]

for url in bad_urls:
    ok, reason, _ = validate_url(url, allow_private=False)
    if ok:
        print(f"FAIL: Expected rejection for {url}, but got accepted! ({reason})", file=sys.stderr)
        sys.exit(1)
    else:
        print(f"OK: Blocked {url} -> {reason}")

# 2. Valid Public URLs
good_urls = [
    "https://api.github.com/repos",
    "https://speed.cloudflare.com/test",
    "http://example.com/index.html",
]

for url in good_urls:
    ok, reason, canonical = validate_url(url, allow_private=False)
    if not ok:
        print(f"FAIL: Expected acceptance for {url}, but got rejected! ({reason})", file=sys.stderr)
        sys.exit(1)
    else:
        print(f"OK: Allowed {url} -> {canonical}")

print("All SSRF unit tests passed.")
EOF

assert_true "SSRF validation test suite completed" test $? -eq 0

echo ""
echo "SSRF test summary: $TEST_PASSED passed, $TEST_FAILED failed."
if [ "$TEST_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
