"""
Phase 2: Distributed BURST Range Planner & Decision Engine.
Implements HTTP Range validation, dynamic chunking, work stealing, and auto-mode evaluation.
"""
import hashlib
import math
import os
import re
import time
from typing import Any, Dict, List, Optional, Tuple
import httpx

from fleet.models import ChunkStatus, DownloadChunk, JobMode, NodeRecord, ProbeResult
from fleet.ssrf import validate_url


def validate_range_support(url: str, timeout: float = 10.0) -> Tuple[bool, int, str, str]:
    """
    Perform a strict Range: bytes=0-0 probe to verify actual HTTP 206 support.
    Returns (supported, total_length, etag, last_modified).
    """
    safe, reason, final_url = validate_url(url)
    if not safe:
        return False, 0, "", ""
    
    headers = {
        "User-Agent": "CyberVPS-FleetTransfer/2.0",
        "Range": "bytes=0-0",
    }
    try:
        with httpx.Client(timeout=timeout, follow_redirects=True) as client:
            resp = client.get(final_url or url, headers=headers)
            etag = resp.headers.get("etag", "").strip('"\'')
            last_mod = resp.headers.get("last-modified", "")
            
            # Check for HTTP 206 Partial Content
            if resp.status_code == 206:
                content_range = resp.headers.get("content-range", "")
                # e.g., "bytes 0-0/104857600"
                match = re.search(r"bytes\s+0-0/(\d+)", content_range, re.IGNORECASE)
                if match:
                    total_len = int(match.group(1))
                    return True, total_len, etag, last_mod
            
            # If server ignored Range and gave 200, Range is NOT supported
            return False, 0, etag, last_mod
    except Exception:
        return False, 0, "", ""


def evaluate_burst_eligibility(
    probe: ProbeResult,
    online_nodes: List[NodeRecord],
    requested_mode: JobMode = JobMode.AUTO,
) -> Tuple[str, str]:
    """
    Evaluate whether a job should run in SINGLE, BURST, or MIRROR mode.
    Returns (resolved_mode, reason).
    """
    # Filter out drained nodes
    eligible_nodes = [n for n in online_nodes if not getattr(n, "is_drained", False)]
    
    if requested_mode == JobMode.SINGLE:
        return "SINGLE", "Single node download mode explicitly requested."
    
    if requested_mode == JobMode.MIRROR:
        if len(eligible_nodes) < 1:
            return "SINGLE", "No eligible nodes for mirror; falling back to single."
        return "MIRROR", "Mirror replication mode requested."
    
    if requested_mode == JobMode.BURST:
        if not probe.accept_ranges:
            return "SINGLE", "Origin does not support HTTP Range; falling back to single node."
        if len(eligible_nodes) < 2:
            return "SINGLE", "Fewer than 2 eligible online nodes available; falling back to single node."
        if probe.expected_size <= 0:
            return "SINGLE", "File size unknown; falling back to single node."
        return "BURST", "Burst multi-node mode explicitly requested and origin supports HTTP Range."

    # AUTO Mode Evaluation
    if not probe.accept_ranges:
        return "SINGLE", "Origin does not support HTTP Range requests."
    
    if probe.expected_size <= 0:
        return "SINGLE", "Content length is unknown; single stream required."
        
    if len(eligible_nodes) < 2:
        return "SINGLE", "Only 1 eligible node online in fleet."

    # For tiny files (< 100 MB), inter-node assembly overhead exceeds parallel download benefit
    if probe.expected_size < 100 * 1024 * 1024:
        return "SINGLE", "File size < 100MB; single stream download is more efficient than multi-node assembly."

    # Calculate expected Single vs Burst transfer times
    speeds = []
    for n in eligible_nodes:
        # Prefer recent real speed, then benchmark DL, default 50 MB/s
        s = n.recent_avg_speed_bps or n.last_benchmark_dl_bps or (50 * 1024 * 1024 * 8)
        speeds.append(max(1024 * 1024 * 8, s))

    speeds.sort(reverse=True)
    best_single_speed_bps = speeds[0]
    aggregate_speed_bps = sum(speeds[:min(len(speeds), 8)]) # Cap at 8 workers for burst estimation

    single_time_sec = (probe.expected_size * 8.0) / best_single_speed_bps
    # Burst time: download time across workers + 20% assembly / transfer overhead
    burst_time_sec = ((probe.expected_size * 8.0) / aggregate_speed_bps) + 4.0

    if burst_time_sec < single_time_sec * 0.85: # Require at least 15% estimated speedup
        return "BURST", (
            f"Burst mode selected: estimated {round(burst_time_sec, 1)}s across {min(len(speeds), 8)} workers "
            f"vs {round(single_time_sec, 1)}s on single node."
        )
    else:
        return "SINGLE", (
            f"Single node selected: {round(single_time_sec, 1)}s is comparable to burst with assembly overhead "
            f"({round(burst_time_sec, 1)}s)."
        )


def calculate_adaptive_chunk_size(total_size: int, node_count: int = 1, active_workers: Optional[int] = None) -> int:
    """
    Calculate optimal chunk size in bytes based on file size and node count.
    Ensures work stealing queue has enough chunks (typically 2x to 4x node count).
    """
    if active_workers is not None:
        node_count = active_workers
    if total_size <= 0:
        return 64 * 1024 * 1024

    if total_size < 1024 * 1024 * 1024:  # < 1GB
        target = 64 * 1024 * 1024  # 64MB
    elif total_size < 5 * 1024 * 1024 * 1024:  # 1GB - 5GB
        target = 128 * 1024 * 1024  # 128MB
    elif total_size < 50 * 1024 * 1024 * 1024:  # 5GB - 50GB
        target = 256 * 1024 * 1024  # 256MB
    else:  # 50GB+
        target = 512 * 1024 * 1024  # 512MB

    # Ensure at least node_count * 2 chunks if possible
    min_chunks = max(4, node_count * 2)
    chunk_size = min(target, total_size // min_chunks)
    # Don't drop below 8MB per chunk to prevent excessive chunk overhead
    return max(8 * 1024 * 1024, chunk_size)


def create_chunk_plan(
    job_id: str,
    total_size: int,
    nodes: List[NodeRecord],
    assembler_node_id: Optional[str] = None
) -> List[DownloadChunk]:
    """
    Generate an ordered, non-overlapping list of byte chunks covering [0, total_size - 1].
    Initial chunks are assigned round-robin to eligible nodes, while remaining chunks
    stay PENDING for work stealing as nodes finish early.
    """
    eligible_nodes = [n for n in nodes if not getattr(n, "is_drained", False)]
    chunk_size = calculate_adaptive_chunk_size(total_size, len(eligible_nodes))
    
    chunks: List[DownloadChunk] = []
    chunk_idx = 0
    start_byte = 0
    now = time.time()

    while start_byte < total_size:
        end_byte = min(start_byte + chunk_size - 1, total_size - 1)
        length = end_byte - start_byte + 1
        cid = f"chk_{job_id}_{chunk_idx:04d}"

        # Assign initial chunks to available nodes; excess chunks remain PENDING for work stealing
        assigned_node = eligible_nodes[chunk_idx % len(eligible_nodes)].id if (chunk_idx < len(eligible_nodes) and eligible_nodes) else None
        status = ChunkStatus.ASSIGNED if assigned_node else ChunkStatus.PENDING

        chunks.append(
            DownloadChunk(
                chunk_id=cid,
                job_id=job_id,
                chunk_index=chunk_idx,
                start_byte=start_byte,
                end_byte=end_byte,
                expected_length=length,
                downloaded_bytes=0,
                node_id=assigned_node,
                status=status,
                attempt_count=1 if assigned_node else 0,
                speed_bps=0.0,
                created_at=now,
                started_at=now if assigned_node else 0.0,
                completed_at=0.0,
                local_path="",
            )
        )
        chunk_idx += 1
        start_byte = end_byte + 1

    return chunks


def select_assembler_node(
    nodes: List[NodeRecord],
    required_size: int = 0,
    expected_size: Optional[int] = None,
) -> Optional[NodeRecord]:
    """
    Select the optimal node to assemble the final file.
    Must have sufficient free disk (at least 1.5x expected file size),
    low active job count, high network capacity, and healthy status.
    """
    if expected_size is not None:
        required_size = expected_size

    # Reserve 10% disk plus 1.5x file size
    safety_margin = int(required_size * 1.5)
    
    candidates = []
    for n in nodes:
        status_val = n.status.value if hasattr(n.status, "value") else str(n.status)
        if getattr(n, "is_drained", False) or status_val != "ONLINE":
            continue
        if n.disk_free_bytes >= safety_margin:
            candidates.append(n)
            
    if not candidates:
        # Fallback to node with most free disk
        active = [n for n in nodes if not getattr(n, "is_drained", False) and n.status.value == "ONLINE"]
        if not active:
            return None
        return max(active, key=lambda x: x.disk_free_bytes)

    # Score candidates: disk (40%) + network capacity (30%) + low jobs (20%) + reliability (10%)
    def score(n: NodeRecord) -> float:
        disk_score = min(1.0, n.disk_free_bytes / (safety_margin * 4 or 1))
        speed = n.last_benchmark_dl_bps or (100 * 1024 * 1024 * 8)
        net_score = min(1.0, speed / (1000 * 1024 * 1024 * 8))
        jobs_score = max(0.0, 1.0 - (n.active_jobs_count * 0.2))
        rel_score = n.reliability_score / 100.0
        return (disk_score * 0.4) + (net_score * 0.3) + (jobs_score * 0.2) + (rel_score * 0.1)

    candidates.sort(key=score, reverse=True)
    return candidates[0]
