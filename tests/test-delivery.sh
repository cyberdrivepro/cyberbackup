#!/usr/bin/env bash
# tests/test-delivery.sh — Cybershare Signed Links & Range Streaming Tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"

log_header "Testing Cybershare Signed Links & Delivery Engine"

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
import tempfile
from pathlib import Path
from fleet.delivery import (
    generate_signed_token,
    parse_and_verify_token,
    is_safe_path,
    get_range_stream,
)

signing_key = "test" + "-signing-key-12345"

# 1. Token Generation & Verification
tok = generate_signed_token("job_xyz123", signing_key, ttl_seconds=3600)
valid, jid, err = parse_and_verify_token(tok, signing_key)
assert valid is True, f"Expected valid token: {err}"
assert jid == "job_xyz123", f"Expected job_xyz123, got {jid}"
print("OK: Valid token verified correctly")

# 2. Expired Token Rejection
expired_tok = generate_signed_token("job_old", signing_key, ttl_seconds=-10)
valid_exp, _, err_exp = parse_and_verify_token(expired_tok, signing_key)
assert valid_exp is False, "Expired token must be rejected"
assert "expired" in (err_exp or "").lower(), f"Expected expiry error, got: {err_exp}"
print(f"OK: Expired token rejected -> {err_exp}")

# 3. Tampered Token Rejection
tampered_tok = tok[:-3] + "abc"
valid_tamp, _, err_tamp = parse_and_verify_token(tampered_tok, signing_key)
assert valid_tamp is False, "Tampered token must be rejected"
print(f"OK: Tampered token rejected -> {err_tamp}")

# 4. Path Traversal Boundary Protection
with tempfile.TemporaryDirectory() as tmpdir:
    allowed_root = Path(tmpdir)
    safe_file = allowed_root / "downloads" / "file.iso"
    safe_file.parent.mkdir(parents=True, exist_ok=True)
    safe_file.write_bytes(b"HELLO WORLD TEST 12345")

    assert is_safe_path(safe_file, [allowed_root]) is True, "Safe child file must be allowed"
    
    evil_file = Path("/etc/passwd")
    assert is_safe_path(evil_file, [allowed_root]) is False, "Path outside allowed root must be rejected"
    
    traversal_path = allowed_root / ".." / ".." / "etc" / "passwd"
    assert is_safe_path(traversal_path, [allowed_root]) is False, "Traversal path must be rejected"
    print("OK: Path traversal protection verified")

    # 5. HTTP Range Streaming (Full & Partial)
    # Full download (status 200)
    status, headers, gen = get_range_stream(safe_file)
    assert status == 200, f"Expected 200 OK, got {status}"
    content = b"".join(gen)
    assert content == b"HELLO WORLD TEST 12345", f"Content mismatch: {content}"
    assert headers["Content-Length"] == str(len(content))
    print("OK: Full HTTP stream verified")

    # Partial range download (bytes=0-4 -> "HELLO")
    status_p, headers_p, gen_p = get_range_stream(safe_file, range_header="bytes=0-4")
    assert status_p == 206, f"Expected 206 Partial Content, got {status_p}"
    content_p = b"".join(gen_p)
    assert content_p == b"HELLO", f"Expected 'HELLO', got {content_p}"
    assert headers_p["Content-Range"] == f"bytes 0-4/{len(content)}"
    assert headers_p["Content-Length"] == "5"
    print("OK: HTTP Range 206 Partial Content stream verified")

print("All delivery unit tests passed.")
EOF

assert_true "Delivery tests completed successfully" test $? -eq 0

echo ""
echo "Delivery test summary: $TEST_PASSED passed, $TEST_FAILED failed."
if [ "$TEST_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
