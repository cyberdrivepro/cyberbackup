"""
Phase 2: Cryptographic Inter-Node Transfer Tickets.
Issues and validates job-scoped, chunk-scoped, time-limited HMAC transfer tokens for node-to-node transfers.
"""
import base64
import hashlib
import hmac
import os
from pathlib import Path
import time
from typing import Optional, Tuple

from fleet.models import TransferTicket


def generate_transfer_ticket(
    signing_secret: str,
    job_id: str,
    chunk_id: str,
    source_node: str,
    destination_node: str,
    ttl_seconds: int = 3600,
) -> TransferTicket:
    """
    Generate a cryptographic HMAC-SHA256 transfer ticket.
    """
    nonce = os.urandom(8).hex()
    expires_at = time.time() + ttl_seconds
    
    # Message format: job_id:chunk_id:source_node:destination_node:expires_at:nonce
    payload = f"{job_id}:{chunk_id}:{source_node}:{destination_node}:{expires_at}:{nonce}"
    sig = hmac.new(signing_secret.encode(), payload.encode(), hashlib.sha256).hexdigest()
    ticket_id = f"tkt_{chunk_id}_{nonce[:6]}"
    
    return TransferTicket(
        ticket_id=ticket_id,
        job_id=job_id,
        chunk_id=chunk_id,
        source_node=source_node,
        destination_node=destination_node,
        expires_at=expires_at,
        nonce=nonce,
        signature=sig,
        used=False,
    )


def verify_transfer_ticket(
    ticket: TransferTicket,
    signing_secret: str,
    expected_chunk_id: Optional[str] = None,
    expected_source_node: Optional[str] = None,
) -> Tuple[bool, str]:
    """
    Verify ticket signature, expiration, and expected chunk/node scoping.
    """
    if time.time() > ticket.expires_at:
        return False, "Transfer ticket has expired"
        
    if expected_chunk_id and ticket.chunk_id != expected_chunk_id:
        return False, f"Ticket chunk mismatch: expected {expected_chunk_id}, got {ticket.chunk_id}"
        
    if expected_source_node and ticket.source_node != expected_source_node:
        return False, f"Ticket source node mismatch: expected {expected_source_node}, got {ticket.source_node}"

    payload = f"{ticket.job_id}:{ticket.chunk_id}:{ticket.source_node}:{ticket.destination_node}:{ticket.expires_at}:{ticket.nonce}"
    expected_sig = hmac.new(signing_secret.encode(), payload.encode(), hashlib.sha256).hexdigest()
    
    if not hmac.compare_digest(ticket.signature, expected_sig):
        return False, "Invalid cryptographic transfer signature"
        
    return True, ""


def is_safe_chunk_path(base_dir: Path, rel_path: str) -> bool:
    """
    Ensure chunk path does not escape the allowed base directory via path traversal.
    """
    try:
        base = Path(base_dir).resolve()
        target = (base / rel_path).resolve()
        return target == base or base in target.parents
    except Exception:
        return False
