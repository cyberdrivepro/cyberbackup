#!/usr/bin/env bash
# tests/test-downloader.sh — Smart Adaptive Downloader Unit & Integration Tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"

log_header "Testing Smart Downloader Engine"

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
import hashlib
import http.server
from pathlib import Path
import socketserver
import sys
import tempfile
import threading
import time

from fleet.downloader import (
    SmartDownloader,
    compute_file_sha256,
    get_adaptive_connections,
)

# 1. Test Adaptive Connection Scaling
assert get_adaptive_connections(1024, accept_ranges=False) == 1, "Must be 1 when Accept-Ranges is False"
assert get_adaptive_connections(2 * 1024 * 1024, accept_ranges=True) == 1, "Tiny file must use 1 conn"
assert get_adaptive_connections(20 * 1024 * 1024, accept_ranges=True) == 4, "Small file must use 4 conns"
assert get_adaptive_connections(200 * 1024 * 1024, accept_ranges=True) == 8, "Medium file must use 8 conns"
assert get_adaptive_connections(2000 * 1024 * 1024, accept_ranges=True) == 16, "Large file must use 16 conns"
print("OK: Adaptive connection scaling verified")

# 2. Local HTTP Server Fixture for Download Execution
with tempfile.TemporaryDirectory() as srv_dir, tempfile.TemporaryDirectory() as dl_dir:
    srv_path = Path(srv_dir)
    test_content = b"CYBERVPS TRANSFER TEST PAYLOAD " * 5000  # ~155 KB
    test_file = srv_path / "sample.bin"
    test_file.write_bytes(test_content)
    expected_sha256 = hashlib.sha256(test_content).hexdigest()

    # Serve files from srv_dir
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=srv_dir, **kwargs)
        def log_message(self, format, *args):
            pass

    httpd = socketserver.TCPServer(("127.0.0.1", 0), Handler)
    port = httpd.server_address[1]
    server_thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    server_thread.start()

    progress_events = []
    def on_progress(dl, tot, speed, eta):
        progress_events.append((dl, tot))

    downloader = SmartDownloader(
        url=f"http://127.0.0.1:{port}/sample.bin",
        dest_dir=dl_dir,
        filename="downloaded_sample.bin",
        expected_size=len(test_content),
        accept_ranges=True,
        progress_callback=on_progress,
    )

    ok, final_path, sha256, downloaded_bytes, elapsed, err = downloader.download()
    httpd.shutdown()

    assert ok is True, f"Download failed: {err}"
    assert Path(final_path).exists(), "Final file must exist"
    assert downloaded_bytes == len(test_content), f"Downloaded bytes mismatch: {downloaded_bytes}"
    assert sha256 == expected_sha256, f"SHA256 mismatch: {sha256} vs {expected_sha256}"
    assert not Path(f"{final_path}.part").exists(), ".part file must be cleaned up on completion"
    assert len(progress_events) > 0, "Progress callback should have been called"
    print(f"OK: Download completed successfully ({downloaded_bytes} bytes in {elapsed:.2f}s, SHA256: {sha256[:16]}...)")

print("All downloader unit tests passed.")
EOF

assert_true "Downloader tests completed successfully" test $? -eq 0

echo ""
echo "Downloader test summary: $TEST_PASSED passed, $TEST_FAILED failed."
if [ "$TEST_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
