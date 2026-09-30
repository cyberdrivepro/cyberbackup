"""
Phase 3: CyberNet Gateway Scoring, WireGuard Config Generation & Session Manager.
Calculates multi-profile gateway scores, assigns virtual IPs, and prepares VPN configs.
"""
import hashlib
import ipaddress
import secrets
import time
from typing import Any, Dict, List, Optional, Tuple

from fleet.models import (
    CyberNetGatewayInfo,
    CyberNetScoreProfile,
    CyberNetProtocol,
    NodeRecord,
)


def calculate_gateway_score(
    gateway: CyberNetGatewayInfo,
    node: Optional[NodeRecord],
    profile: CyberNetScoreProfile = CyberNetScoreProfile.BALANCED,
) -> float:
    """
    Computes a truthful gateway suitability score [0.0 - 100.0].
    Takes into account latency, packet loss, real load, effective RAM, and active sessions.
    """
    if not gateway.enabled:
        return 0.0

    if node:
        # Check node status
        if getattr(node, "status", None) and node.status.value != "ONLINE":
            return 0.0
        if getattr(node, "is_drained", False):
            return 0.0

        # Memory health guard: do not route VPN through nodes with < 100MB free RAM
        effective_ram = getattr(node, "effective_ram_bytes", 0)
        ram_used = getattr(node, "ram_used_bytes", 0)
        free_ram = max(0, effective_ram - ram_used) if effective_ram > 0 else 512 * 1024 * 1024
        if effective_ram > 0 and free_ram < 100 * 1024 * 1024:
            return 5.0 # Severely deprioritize low-RAM nodes to avoid OOM
    else:
        free_ram = 512 * 1024 * 1024

    # 1. Latency component (0ms -> 100pts, 300ms+ -> 0pts)
    lat = max(1.0, gateway.latency_ms if gateway.latency_ms > 0 else 50.0)
    latency_score = max(0.0, 100.0 - (lat / 3.0))

    # 2. Packet loss component (0% -> 100pts, 10%+ -> 0pts)
    loss = max(0.0, min(100.0, gateway.packet_loss))
    loss_score = max(0.0, 100.0 - (loss * 10.0))

    # 3. Resource & Load component
    cpu_pct = 10.0
    if node and hasattr(node, "effective_cpu") and node.effective_cpu > 0:
        # Approximate load from active jobs and sessions
        cpu_pct = min(100.0, (gateway.active_sessions * 5.0) + (getattr(node, "active_jobs_count", 0) * 15.0))
    load_score = max(0.0, 100.0 - cpu_pct)

    # 4. Throughput capability component (scaled to 10 Gbps)
    speed_mbps = 100.0
    if node and hasattr(node, "last_benchmark_dl_bps") and node.last_benchmark_dl_bps > 0:
        speed_mbps = node.last_benchmark_dl_bps / 1_000_000.0
    throughput_score = min(100.0, max(5.0, (speed_mbps / 10000.0) * 100.0))

    # 5. Session balancing penalty (1pt deducted per active session up to 30)
    session_penalty = min(30.0, gateway.active_sessions * 1.5)

    # Profile Weighting
    if profile == CyberNetScoreProfile.LOW_LATENCY:
        score = (latency_score * 0.60) + (loss_score * 0.25) + (load_score * 0.15) - session_penalty
    elif profile == CyberNetScoreProfile.MAX_THROUGHPUT:
        score = (throughput_score * 0.70) + (load_score * 0.15) + (latency_score * 0.10) + (loss_score * 0.05) - session_penalty
    elif profile == CyberNetScoreProfile.STREAMING:
        score = (throughput_score * 0.35) + (loss_score * 0.35) + (latency_score * 0.20) + (load_score * 0.10) - session_penalty
    else:  # BALANCED (default)
        score = (latency_score * 0.40) + (loss_score * 0.15) + (load_score * 0.25) + (throughput_score * 0.15) + (min(100.0, free_ram / (1024*1024*10)) * 0.05) - session_penalty

    return round(max(1.0, min(100.0, score)), 2)


def select_best_gateways(
    gateways: List[CyberNetGatewayInfo],
    nodes_by_id: Dict[str, NodeRecord],
    profile: CyberNetScoreProfile = CyberNetScoreProfile.BALANCED,
    preferred_gateway_id: Optional[str] = None,
    limit: int = 3,
) -> Tuple[Optional[CyberNetGatewayInfo], List[CyberNetGatewayInfo]]:
    """
    Selects the primary gateway and an ordered list of backup gateways for fast failover.
    """
    scored: List[Tuple[float, CyberNetGatewayInfo]] = []

    for gw in gateways:
        if not gw.enabled:
            continue
        node = nodes_by_id.get(gw.node_id)
        if node and getattr(node, "status", None) and node.status.value != "ONLINE":
            continue
        
        score = calculate_gateway_score(gw, node, profile)
        gw.gateway_score = score
        scored.append((score, gw))

    # Sort descending by score
    scored.sort(key=lambda x: x[0], reverse=True)

    if not scored:
        return None, []

    # If user explicitly preferred a gateway that is online
    primary: Optional[CyberNetGatewayInfo] = None
    if preferred_gateway_id:
        for s, gw in scored:
            if gw.node_id == preferred_gateway_id:
                primary = gw
                break

    if not primary:
        primary = scored[0][1]

    # Collect backups (excluding primary)
    backups = [gw for s, gw in scored if gw.node_id != primary.node_id][:limit]

    return primary, backups


def allocate_client_ip(
    subnet: str,
    active_ips: List[str],
) -> str:
    """
    Allocates the next available client IP from the gateway WireGuard subnet.
    Defaults to 10.66.0.2 to 10.66.0.254.
    """
    net = ipaddress.ip_network(subnet, strict=False)
    used_set = set(active_ips)
    
    # Gateway uses first usable IP (e.g. 10.66.0.1)
    gateway_ip = str(list(net.hosts())[0])
    used_set.add(gateway_ip)

    for host in net.hosts():
        ip_str = str(host)
        if ip_str not in used_set:
            return ip_str

    # Fallback pseudo-random allocation if subnet is densely packed
    return f"10.66.0.{secrets.randbelow(200) + 10}"


def generate_wireguard_client_config(
    client_private_key: str,
    client_ip: str,
    gateway_public_key: str,
    gateway_endpoint: str,
    dns_servers: Optional[List[str]] = None,
    allowed_ips: str = "0.0.0.0/0, ::/0",
    persistent_keepalive: int = 25,
) -> str:
    """
    Generates standard WireGuard client configuration file contents.
    """
    dns_line = f"DNS = {', '.join(dns_servers)}" if dns_servers else "DNS = 1.1.1.1, 1.0.0.1"
    return f"""[Interface]
PrivateKey = {client_private_key}
Address = {client_ip}/32
{dns_line}

[Peer]
PublicKey = {gateway_public_key}
Endpoint = {gateway_endpoint}
AllowedIPs = {allowed_ips}
PersistentKeepalive = {persistent_keepalive}
"""


def generate_ssh_tunnel_config(
    gateway_host: str,
    ssh_port: int,
    username: str,
    device_id: str,
    socks_port: int = 1080,
    dns_servers: Optional[List[str]] = None,
) -> Dict[str, Any]:
    """
    Generates configuration for Tun2Socks + SSH tunnel fallback.
    """
    return {
        "gateway_host": gateway_host,
        "ssh_port": ssh_port,
        "username": username,
        "device_id": device_id,
        "socks_port": socks_port,
        "dns_servers": dns_servers or ["1.1.1.1", "1.0.0.1"],
        "tun2socks_cmd": f"tun2socks -device tun0 -proxy socks5://127.0.0.1:{socks_port}",
    }


def resolve_dns_preset(preset: str, custom: Optional[str] = None) -> List[str]:
    """
    Resolves DNS preset mode into concrete server IP list.
    """
    mode = preset.upper()
    if mode == "GOOGLE":
        return ["8.8.8.8", "8.8.4.4"]
    elif mode == "QUAD9":
        return ["9.9.9.9", "149.112.112.112"]
    elif mode == "CUSTOM" and custom:
        return [c.strip() for c in custom.split(",") if c.strip()]
    elif mode == "SYSTEM":
        return ["1.1.1.1"] # Fallback for mobile system resolver
    else:  # CLOUDFLARE (default)
        return ["1.1.1.1", "1.0.0.1"]
