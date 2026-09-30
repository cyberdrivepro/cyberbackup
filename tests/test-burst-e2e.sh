#!/usr/bin/env bash
# tests/test-burst-e2e.sh — Phase 2 BURST Multi-Worker End-to-End Assembly & Recovery Tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"

log_header "Testing Phase 2 BURST Multi-Worker End-to-End & Recovery"

PYTHONPATH="$REPO_DIR" python3 - << 'EOF'
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import os
from pathlib import Path
import tempfile
import threading
import time

from fleet.assembler import BurstAssembler
from fleet.downloader import download_byte_range

# Create mock test payload (1MB with distinct patterns)
payload_size = 1024 * 1024 # 1 MB
test_payload = os.urandom(payload_size)
expected_sha = hashlib.sha256(test_payload).hexdigest()

# Mock HTTP Server with strict RFC 7233 HTTP Range support
class RangeHttpHandler(BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(len(test_payload)))
        self.send_header("Content-Type", "application/octet-stream")
        self.end_headers()

    def do_GET(self):
        range_header = self.headers.get("Range")
        if range_header and range_header.startswith("bytes="):
            r = range_header.replace("bytes=", "").split("-")
            start = int(r[0])
            end = int(r[1]) if r[1] else len(test_payload) - 1
            end = min(end, len(test_payload) - 1)
            chunk_data = test_payload[start:end+1]

            self.send_response(206)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(test_payload)}")
            self.send_header("Content-Length", str(len(chunk_data)))
            self.end_headers()
            self.wfile.write(chunk_data)
        else:
            self.send_response(200)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(len(test_payload)))
            self.send_header("Content-Type", "application/octet-stream")
            self.end_headers()
            self.wfile.write(test_payload)

    def log_message(self, format, *args):
        pass

# Start local server on loopback
server = HTTPServer(("127.0.0.1", 0), RangeHttpHandler)
port = server.server_port
server_thread = threading.Thread(target=server.serve_forever, daemon=True)
server_thread.start()
server_url = f"http://127.0.0.1:{port}/testfile.bin"

with tempfile.TemporaryDirectory() as tmpdir:
    dest_dir = Path(tmpdir)
    chunks_dir = dest_dir / "chunks"
    chunks_dir.mkdir(parents=True, exist_ok=True)

    # 1. Multi-Worker Concurrent BURST Download
    # Partition into 4 chunks of 256KB
    chunk_size = 256 * 1024
    chunk_ranges = [
        (0, 0, 256 * 1024 - 1),
        (1, 256 * 1024, 512 * 1024 - 1),
        (2, 512 * 1024, 768 * 1024 - 1),
        (3, 768 * 1024, 1024 * 1024 - 1),
    ]

    assembler = BurstAssembler(
        job_id="job_e2e_burst",
        total_size=payload_size,
        dest_dir=dest_dir,
        filename="assembled_final.bin",
    )

    downloaded_chunks = {}
    threads = []

    def worker_fetch(c_idx, start_b, end_b):
        c_path = chunks_dir / f"chunk_{c_idx}.part"
        ok, sha, sz, el, err = download_byte_range(
            url=server_url,
            start_byte=start_b,
            end_byte=end_b,
            dest_path=c_path,
        )
        assert ok, f"Worker failed on chunk {c_idx}: {err}"
        downloaded_chunks[c_idx] = (c_path, start_b)

    for idx, s, e in chunk_ranges:
        t = threading.Thread(target=worker_fetch, args=(idx, s, e))
        threads.append(t)
        t.start()

    for t in threads:
        t.join()

    assert len(downloaded_chunks) == 4, f"All 4 chunks must complete, got {len(downloaded_chunks)}"
    print("OK: Concurrent multi-worker chunk downloads completed")

    # 2. Assemble Chunks via Seek/Offset Writer
    for idx, (path, start_b) in downloaded_chunks.items():
        assembler.write_chunk_from_file(f"chunk_{idx}", start_b, path)

    final_path, final_sha = assembler.finalize(expected_sha256=expected_sha)
    assert final_path.exists(), "Final assembled file must exist"
    assert final_sha == expected_sha, f"SHA-256 mismatch! Expected {expected_sha}, got {final_sha}"
    assert final_path.read_bytes() == test_payload, "Payload bytes do not match original"
    print(f"OK: Assembler offset assembly & SHA-256 verified ({final_sha[:16]}...)")

    # 3. Simulate Worker Failure & Recovery
    # If a worker fails or disconnects mid-chunk:
    # Fail chunk, requeue, and re-download:
    fail_chunk_path = chunks_dir / "failed_chunk.part"
    fail_cancel = threading.Event()
    fail_cancel.set() # Trigger immediate cancellation / failure

    ok_f, _, _, _, err_f = download_byte_range(
        url=server_url,
        start_byte=0,
        end_byte=256 * 1024 - 1,
        dest_path=fail_chunk_path,
        cancel_event=fail_cancel,
    )
    assert not ok_f, "Cancelled chunk must report failure"
    assert "cancelled" in err_f.lower() or "aborted" in err_f.lower()

    # Requeue and retry with new worker:
    ok_retry, sha_retry, _, _, _ = download_byte_range(
        url=server_url,
        start_byte=0,
        end_byte=256 * 1024 - 1,
        dest_path=fail_chunk_path,
    )
    assert ok_retry, "Requeued chunk download must succeed"
    assert sha_retry == hashlib.sha256(test_payload[:256*1024]).hexdigest()
    print("OK: Worker failure mid-transfer cancellation and requeue recovery verified")

server.shutdown()
EOF

log_ok "All Phase 2 BURST End-to-End tests passed successfully!"
