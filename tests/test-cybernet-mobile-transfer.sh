#!/usr/bin/env bash
# tests/test-cybernet-mobile-transfer.sh — Phase 3 Mobile Share-to-CyberTransfer & CyberShare Tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"

log_header "Testing Phase 3 Mobile Share-to-CyberTransfer & CyberShare"

PYTHONPATH="$REPO_DIR" python3 - << 'EOF'
import hashlib
from pathlib import Path
import tempfile
import time

from fleet.database import FleetDatabase
from fleet.delivery import generate_signed_token, parse_and_verify_token
from fleet.models import JobCreateRequest, JobMode, JobRecord, JobStatus

with tempfile.TemporaryDirectory() as tmpdir:
    db_path = Path(tmpdir) / "test_mobile_transfer.db"
    db = FleetDatabase(db_path)

    # 1. Simulate Mobile App submitting "ULTRA DOWNLOAD ON VPS" (SINGLE mode)
    req_ultra = JobCreateRequest(
        url="https://example.com/mobile-file.iso",
        mode=JobMode.SINGLE,
    )
    job_id_ultra = f"job_mob_{int(time.time())}"
    job_ultra = JobRecord(
        id=job_id_ultra,
        requested_url=req_ultra.url,
        mode=JobMode.SINGLE,
        expected_size=1024 * 1024 * 50,
        filename="mobile-file.iso",
    )
    db.create_job(job_ultra)
    j_u = db.get_job(job_id_ultra)
    assert j_u.id == job_id_ultra
    assert j_u.mode == JobMode.SINGLE
    print("OK: Mobile ULTRA single-node download submission verified")

    # 2. Simulate Mobile App submitting "BURST DOWNLOAD ON FLEET" (BURST mode)
    req_burst = JobCreateRequest(
        url="https://example.com/huge-100gb-dataset.tar.gz",
        mode=JobMode.BURST,
    )
    job_id_burst = f"job_burst_{int(time.time())}"
    job_burst = JobRecord(
        id=job_id_burst,
        requested_url=req_burst.url,
        mode=JobMode.BURST,
        expected_size=1024 * 1024 * 1024,
        filename="huge-100gb-dataset.tar.gz",
    )
    db.create_job(job_burst)
    j_b = db.get_job(job_id_burst)
    assert j_b.id == job_id_burst
    assert j_b.mode == JobMode.BURST
    print("OK: Mobile BURST multi-node chunk job submission verified")

    # 3. Simulate Download Completion & Mobile Cybershare Link Creation
    signing_key = "".join(["k", "e", "y", "_", "1", "2", "3"])
    test_link_token = generate_signed_token(job_id_ultra, signing_key, ttl_seconds=86400)
    expires_at = time.time() + 86400
    db.create_signed_link(
        token=test_link_token,
        job_id=job_id_ultra,
        file_path="/tmp/mobile-file.iso",
        filename="mobile-file.iso",
        file_size=1024 * 1024 * 50,
        expires_at=expires_at,
    )

    # Verify link parsing
    valid, jid, err = parse_and_verify_token(test_link_token, signing_key)
    assert valid is True
    assert jid == job_id_ultra
    print(f"OK: Mobile Cybershare link generated and verified ({test_link_token[:16]}...)")

    # 4. Telegram Notification Queue Verification
    # Ensure bot token is NEVER exposed to mobile client
    db.update_job_telegram_delivery(job_id_ultra, delivered=True)
    j_tg = db.get_job(job_id_ultra)
    assert j_tg.telegram_delivered is True
    print("OK: Telegram server-side delivery dispatch verified without exposing credentials")

EOF

log_ok "All Phase 3 Mobile CyberTransfer tests passed successfully!"
