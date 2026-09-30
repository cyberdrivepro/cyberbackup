"""
Smart Node Scheduler for CyberTransfer.
Calculates multi-dimensional capacity scores based on real effective resources,
live traffic, historical transfer speed, active workload, and reliability.
"""
from typing import Any, Dict, List, Optional, Tuple


def calculate_node_score(node: Dict[str, Any], expected_size: int = 0) -> Tuple[float, List[str]]:
    """
    Computes a composite capacity score (0-100) for a candidate node.
    Returns: (total_score, reason_components)
    """
    score = 0.0
    reasons = []

    # 1. Disk Free Score (Max 25 pts)
    disk_free = node.get("disk_free_bytes", 0)
    disk_free_gb = disk_free / (1024 ** 3)
    if disk_free_gb >= 100:
        score += 25.0
        reasons.append(f"{disk_free_gb:.1f} GB free disk")
    elif disk_free_gb >= 20:
        score += 20.0
        reasons.append(f"{disk_free_gb:.1f} GB free disk")
    elif disk_free_gb >= 5:
        score += 12.0
        reasons.append(f"{disk_free_gb:.1f} GB free disk")
    else:
        score += max(0.0, disk_free_gb * 2.0)
        reasons.append(f"low disk ({disk_free_gb:.1f} GB)")

    # 2. Active Workload Score (Max 20 pts)
    active_jobs = node.get("active_jobs_count", 0)
    if active_jobs == 0:
        score += 20.0
        reasons.append("idle downloader (0 active jobs)")
    elif active_jobs == 1:
        score += 12.0
        reasons.append("1 active job")
    elif active_jobs == 2:
        score += 6.0
        reasons.append("2 active jobs")
    else:
        score += 1.0
        reasons.append(f"busy ({active_jobs} active jobs)")

    # 3. Real Download Performance History (Max 20 pts)
    recent_speed = node.get("recent_avg_speed_bps", 0.0)
    benchmark_dl = node.get("last_benchmark_dl_bps", 0.0)

    if recent_speed > 0:
        speed_mbps = recent_speed / (1024 * 1024)
        if speed_mbps >= 500:
            score += 20.0
            reasons.append(f"{speed_mbps:.0f} Mbps real throughput")
        elif speed_mbps >= 100:
            score += 16.0
            reasons.append(f"{speed_mbps:.0f} Mbps real throughput")
        elif speed_mbps >= 25:
            score += 11.0
            reasons.append(f"{speed_mbps:.0f} Mbps real throughput")
        else:
            score += 6.0
            reasons.append(f"{speed_mbps:.1f} Mbps real throughput")
    elif benchmark_dl > 0:
        bench_mbps = benchmark_dl / (1024 * 1024)
        score += min(15.0, 5.0 + (bench_mbps / 100.0) * 10.0)
        reasons.append(f"{bench_mbps:.0f} Mbps benchmark")
    else:
        score += 10.0  # Baseline unbenchmarked score

    # 4. Live Traffic Utilization (Max 15 pts)
    live_rx = node.get("live_rx_bps", 0.0)
    live_tx = node.get("live_tx_bps", 0.0)
    total_live_mbps = (live_rx + live_tx) / (1024 * 1024)

    if total_live_mbps < 5.0:
        score += 15.0
    elif total_live_mbps < 50.0:
        score += 10.0
    elif total_live_mbps < 200.0:
        score += 5.0
    else:
        score += 1.0
        reasons.append(f"high traffic ({total_live_mbps:.0f} Mbps)")

    # 5. Effective RAM Availability (Max 10 pts)
    ram_total = node.get("effective_ram_bytes", 0)
    ram_used = node.get("ram_used_bytes", 0)
    ram_free_mb = max(0, (ram_total - ram_used) / (1024 * 1024)) if ram_total > 0 else 512

    if ram_free_mb >= 512:
        score += 10.0
    elif ram_free_mb >= 256:
        score += 7.0
    elif ram_free_mb >= 64:
        score += 4.0
    else:
        score += 1.0
        reasons.append(f"low RAM ({ram_free_mb:.0f} MB free)")

    # 6. Reliability History (Max 10 pts)
    reliability = float(node.get("reliability_score", 100.0))
    score += (reliability / 100.0) * 10.0
    if reliability >= 99.0:
        reasons.append(f"{reliability:.1f}% reliability")

    return score, reasons


def select_best_node(
    nodes: List[Dict[str, Any]],
    expected_size: int = 0,
    preferred_node: Optional[str] = None,
    safety_reserve_bytes: int = 1073741824  # 1 GB safety reserve
) -> Tuple[Optional[Dict[str, Any]], str]:
    """
    Selects the optimal candidate node from all registered nodes.
    Returns: (selected_node, selection_reason)
    """
    if not nodes:
        return None, "No nodes registered in CyberFleet"

    # Filter out ineligible nodes
    eligible = []
    rejection_reasons = []

    for node in nodes:
        node_id = node.get("id") or node.get("name")
        status = node.get("status", "OFFLINE")

        if status != "ONLINE":
            rejection_reasons.append(f"Node '{node.get('name')}' is {status}")
            continue

        # Check disk reserve if expected size is known
        disk_free = node.get("disk_free_bytes", 0)
        required_disk = expected_size + safety_reserve_bytes
        if expected_size > 0 and disk_free > 0 and disk_free < required_disk:
            rejection_reasons.append(
                f"Node '{node.get('name')}' has insufficient disk ({disk_free // (1024**2)} MB < required {required_disk // (1024**2)} MB)"
            )
            continue

        eligible.append(node)

    if not eligible:
        detail = "; ".join(rejection_reasons) if rejection_reasons else "All nodes offline or saturated"
        return None, f"No healthy nodes available ({detail})"

    # If caller specifically requested a preferred node
    if preferred_node:
        for node in eligible:
            if node.get("name") == preferred_node or node.get("id") == preferred_node:
                return node, f"Selected preferred node '{node.get('name')}' (verified online and healthy)"

    # Score all eligible nodes
    best_node = None
    best_score = -1.0
    best_reasons = []

    for node in eligible:
        score, reasons = calculate_node_score(node, expected_size=expected_size)
        if score > best_score:
            best_score = score
            best_node = node
            best_reasons = reasons

    if not best_node:
        return eligible[0], f"Selected node '{eligible[0].get('name')}' (default online fallback)"

    reason_summary = ", ".join(best_reasons[:4])
    explanation = f"Selected Node: {best_node.get('name')} (Score: {best_score:.1f}/100, Reason: {reason_summary})"
    return best_node, explanation
