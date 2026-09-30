"""
Cybershare Signed Link Delivery Engine.
Generates cryptographically signed expiring file links and streams files
with HTTP Range partial content (206) support and path traversal protection.
"""
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import time
from typing import Dict, Generator, Optional, Tuple


def generate_signed_token(job_id: str, secret_key: str, ttl_seconds: int = 86400) -> str:
    """Generates a URL-safe signed HMAC token encoding job_id and expiration."""
    expires_at = time.time() + ttl_seconds
    nonce = os.urandom(8).hex()
    payload = f"{job_id}:{expires_at}:{nonce}"
    sig = hmac.new(secret_key.encode("utf-8"), payload.encode("utf-8"), hashlib.sha256).hexdigest()[:32]
    raw = f"{payload}:{sig}"
    return base64.urlsafe_b64encode(raw.encode("utf-8")).decode("utf-8").rstrip("=")


def parse_and_verify_token(token: str, secret_key: str) -> Tuple[bool, Optional[str], Optional[str]]:
    """
    Verifies HMAC signature and expiration of a signed token.
    Returns: (is_valid, job_id, error_message)
    """
    try:
        # Pad base64 if needed
        padding = "=" * (4 - (len(token) % 4)) if len(token) % 4 != 0 else ""
        decoded = base64.urlsafe_b64decode(token + padding).decode("utf-8")
        parts = decoded.split(":")
        if len(parts) != 4:
            return False, None, "Malformed token structure"

        job_id, expires_at_str, nonce, sig = parts
        expires_at = float(expires_at_str)

        # Check expiration
        if time.time() > expires_at:
            return False, job_id, "Download link has expired"

        # Check HMAC signature
        payload = f"{job_id}:{expires_at_str}:{nonce}"
        expected_sig = hmac.new(secret_key.encode("utf-8"), payload.encode("utf-8"), hashlib.sha256).hexdigest()[:32]

        if not hmac.compare_digest(sig, expected_sig):
            return False, None, "Invalid cryptographic signature"

        return True, job_id, None
    except Exception as e:
        return False, None, f"Token verification error: {e}"


def is_safe_path(target_path: Path, allowed_roots: list[Path]) -> bool:
    """Ensures target path resolves strictly within designated allowed directories."""
    try:
        resolved = target_path.resolve()
        for root in allowed_roots:
            resolved_root = root.resolve()
            if resolved == resolved_root or resolved_root in resolved.parents:
                return True
        return False
    except Exception:
        return False


def get_range_stream(
    file_path: Path,
    range_header: Optional[str] = None,
    chunk_size: int = 65536
) -> Tuple[int, Dict[str, str], Generator[bytes, None, None]]:
    """
    Prepares a generator for streaming a file with HTTP Range support.
    Returns: (http_status, headers, byte_generator)
    """
    file_size = file_path.stat().st_size
    filename = file_path.name

    if not range_header or not range_header.startswith("bytes="):
        # Full content response (200 OK)
        headers = {
            "Content-Type": "application/octet-stream",
            "Content-Length": str(file_size),
            "Accept-Ranges": "bytes",
            "Content-Disposition": f'attachment; filename="{filename}"',
        }

        def full_generator():
            with open(file_path, "rb") as f:
                while True:
                    chunk = f.read(chunk_size)
                    if not chunk:
                        break
                    yield chunk

        return 200, headers, full_generator()

    # Parse Range: bytes=start-end
    range_spec = range_header.replace("bytes=", "").strip()
    parts = range_spec.split("-", 1)
    
    start = int(parts[0]) if parts[0] else 0
    end = int(parts[1]) if len(parts) > 1 and parts[1] else (file_size - 1)

    if start >= file_size or end >= file_size or start > end:
        # Invalid range (416 Range Not Satisfiable)
        headers = {
            "Content-Range": f"bytes */{file_size}",
            "Accept-Ranges": "bytes",
        }
        return 416, headers, (b"" for _ in range(0))

    content_length = end - start + 1
    headers = {
        "Content-Type": "application/octet-stream",
        "Content-Range": f"bytes {start}-{end}/{file_size}",
        "Content-Length": str(content_length),
        "Accept-Ranges": "bytes",
        "Content-Disposition": f'attachment; filename="{filename}"',
    }

    def partial_generator():
        with open(file_path, "rb") as f:
            f.seek(start)
            remaining = content_length
            while remaining > 0:
                to_read = min(chunk_size, remaining)
                chunk = f.read(to_read)
                if not chunk:
                    break
                remaining -= len(chunk)
                yield chunk

    return 206, headers, partial_generator()
