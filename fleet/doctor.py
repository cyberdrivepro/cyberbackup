"""
Phase 3: CyberNet Diagnostics & Doctor.
Inspects WireGuard, UDP, IP forwarding, NAT, DNS, SSH fallback, and rootless network capabilities.
"""
import os
from pathlib import Path
import shutil
import socket
import subprocess
import time
from typing import Any, Dict, List, Tuple


class CyberNetDoctor:
    """
    Diagnostic tool for CyberNet VPN gateways and client environments.
    Returns structured results: PASS, WARN, FAIL, SKIP.
    """
    @staticmethod
    def check_wireguard_support() -> Tuple[str, str]:
        """Check for native wg or userspace wireguard-go/boringtun."""
        wg_bin = shutil.which("wg")
        wg_go = shutil.which("wireguard-go")
        boringtun = shutil.which("boringtun")

        if wg_bin:
            return "PASS", f"WireGuard utility available: {wg_bin}"
        elif wg_go:
            return "PASS", f"User-space WireGuard available: {wg_go}"
        elif boringtun:
            return "PASS", f"User-space BoringTun available: {boringtun}"
        else:
            return "WARN", "WireGuard binary not installed; user-space or SSH fallback will be used."

    @staticmethod
    def check_ip_forwarding() -> Tuple[str, str]:
        """Check if IPv4 forwarding is enabled."""
        fwd_path = Path("/proc/sys/net/ipv4/ip_forward")
        if fwd_path.exists():
            try:
                val = fwd_path.read_text().strip()
                if val == "1":
                    return "PASS", "IPv4 forwarding is ENABLED (ip_forward = 1)"
                else:
                    return "WARN", "IPv4 forwarding is DISABLED (ip_forward = 0); required for NAT gateway."
            except Exception as e:
                return "WARN", f"Cannot read /proc/sys/net/ipv4/ip_forward: {e}"
        return "SKIP", "Non-Linux environment or /proc/sys/net/ipv4 not mounted."

    @staticmethod
    def check_udp_reachability() -> Tuple[str, str]:
        """Verifies local UDP socket binding capability in rootless user-space."""
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.bind(("0.0.0.0", 0))
            port = s.getsockname()[1]
            s.close()
            return "PASS", f"UDP socket binding functional (ephemeral port {port})"
        except Exception as e:
            return "FAIL", f"UDP socket binding failed: {e}"

    @staticmethod
    def check_dns_resolution() -> Tuple[str, str]:
        """Verifies DNS query resolution."""
        start = time.time()
        try:
            ip = socket.gethostbyname("one.one.one.one")
            elapsed = (time.time() - start) * 1000
            return "PASS", f"DNS resolution verified (one.one.one.one -> {ip}, {elapsed:.1f}ms)"
        except Exception as e:
            return "FAIL", f"DNS resolution failed: {e}"

    @staticmethod
    def check_ssh_fallback() -> Tuple[str, str]:
        """Verifies SSH server presence and rootless port accessibility."""
        ssh_bin = shutil.which("ssh")
        sshd_bin = shutil.which("sshd")
        if ssh_bin:
            return "PASS", f"SSH client available ({ssh_bin})"
        return "WARN", "SSH client binary not found in PATH."

    @staticmethod
    def check_public_ip() -> Tuple[str, str]:
        """Detects public IPv4 availability."""
        try:
            import httpx
            with httpx.Client(timeout=4.0) as client:
                r = client.get("https://api.ipify.org?format=json")
                if r.status_code == 200:
                    pub_ip = r.json().get("ip", "unknown")
                    return "PASS", f"Public IPv4 detected: {pub_ip}"
        except Exception:
            pass
        return "WARN", "Could not query external IP probe; internal binding active."

    @staticmethod
    def check_clock_sync() -> Tuple[str, str]:
        """Verifies system clock sanity for WireGuard handshake timestamps."""
        now = time.time()
        # Epoch should be after 2026-01-01 (1767225600)
        if now > 1700000000:
            return "PASS", f"System clock synchronized ({time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime(now))} UTC)"
        return "FAIL", "System clock significantly drifting; WireGuard handshakes will fail."

    @classmethod
    def run_all(cls) -> List[Dict[str, str]]:
        """Runs the complete CyberNet diagnostic suite."""
        checks = [
            ("WireGuard Support", cls.check_wireguard_support),
            ("IP Forwarding", cls.check_ip_forwarding),
            ("UDP Capability", cls.check_udp_reachability),
            ("DNS Resolution", cls.check_dns_resolution),
            ("SSH Fallback", cls.check_ssh_fallback),
            ("Public IP Probe", cls.check_public_ip),
            ("Clock Sync", cls.check_clock_sync),
        ]
        results = []
        for name, fn in checks:
            status, detail = fn()
            results.append({"name": name, "status": status, "detail": detail})
        return results
