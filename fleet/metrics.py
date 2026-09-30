"""
Real Effective Resource and Live Network Metrics Engine.
Reads cgroup v2/v1 CPU quotas, effective memory limits, mount overlays,
and computes smoothed RX/TX interface traffic via /proc/net/dev.
"""
import glob
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import time
from typing import Any, Dict, Optional, Tuple


class NetworkTrafficTracker:
    """Tracks live interface bandwidth using exponential moving average (EMA)."""
    def __init__(self, alpha: float = 0.3):
        self.alpha = alpha
        self.last_timestamp: float = 0.0
        self.last_rx_bytes: int = 0
        self.last_tx_bytes: int = 0
        self.ema_rx_bps: float = 0.0
        self.ema_tx_bps: float = 0.0
        # Initialize initial baseline
        self._read_counters()

    def _read_counters(self) -> Tuple[int, int]:
        total_rx = 0
        total_tx = 0
        proc_net_dev = Path("/proc/net/dev")
        if proc_net_dev.is_file():
            try:
                lines = proc_net_dev.read_text().splitlines()
                for line in lines[2:]:
                    if ":" not in line:
                        continue
                    iface, stats = line.split(":", 1)
                    iface = iface.strip()
                    if iface == "lo" or iface.startswith("tun") or iface.startswith("dummy"):
                        continue
                    parts = stats.split()
                    if len(parts) >= 9:
                        rx = int(parts[0])
                        tx = int(parts[8])
                        total_rx += rx
                        total_tx += tx
            except Exception:
                pass
        else:
            # Fallback to /sys/class/net
            for rx_file in glob.glob("/sys/class/net/[!lo]*/statistics/rx_bytes"):
                try:
                    total_rx += int(Path(rx_file).read_text().strip())
                except Exception:
                    pass
            for tx_file in glob.glob("/sys/class/net/[!lo]*/statistics/tx_bytes"):
                try:
                    total_tx += int(Path(tx_file).read_text().strip())
                except Exception:
                    pass
        return total_rx, total_tx

    def sample(self) -> Tuple[float, float]:
        """Samples counters and returns (rx_bytes_per_sec, tx_bytes_per_sec)."""
        now = time.time()
        rx, tx = self._read_counters()
        
        if self.last_timestamp > 0 and now > self.last_timestamp:
            dt = now - self.last_timestamp
            delta_rx = max(0, rx - self.last_rx_bytes)
            delta_tx = max(0, tx - self.last_tx_bytes)
            
            inst_rx_bps = delta_rx / dt
            inst_tx_bps = delta_tx / dt
            
            if self.ema_rx_bps == 0:
                self.ema_rx_bps = inst_rx_bps
                self.ema_tx_bps = inst_tx_bps
            else:
                self.ema_rx_bps = self.alpha * inst_rx_bps + (1.0 - self.alpha) * self.ema_rx_bps
                self.ema_tx_bps = self.alpha * inst_tx_bps + (1.0 - self.alpha) * self.ema_tx_bps
        
        self.last_timestamp = now
        self.last_rx_bytes = rx
        self.last_tx_bytes = tx
        return self.ema_rx_bps, self.ema_tx_bps


def _read_cgroup_file(path: str) -> Optional[str]:
    p = Path(path)
    if p.is_file():
        try:
            return p.read_text().strip()
        except Exception:
            return None
    return None


def _find_cgroup_dir(controller: str = "v2") -> Optional[str]:
    proc_cgroup = Path("/proc/self/cgroup")
    if not proc_cgroup.is_file():
        return None
    try:
        lines = proc_cgroup.read_text().splitlines()
        for line in lines:
            parts = line.split(":", 2)
            if len(parts) == 3:
                num, name, path = parts
                if controller == "v2" and num == "0":
                    candidate = f"/sys/fs/cgroup{path}"
                    if os.path.isdir(candidate):
                        return candidate
                    return "/sys/fs/cgroup"
                elif controller != "v2" and controller in name.split(","):
                    candidate = f"/sys/fs/cgroup/{controller}{path}"
                    if os.path.isdir(candidate):
                        return candidate
                    return f"/sys/fs/cgroup/{controller}"
    except Exception:
        pass
    return None


def get_effective_cpu() -> Tuple[float, int]:
    """Returns (effective_schedulable_cpu, visible_cpu)."""
    visible_cpus = os.cpu_count() or 1
    effective = float(visible_cpus)
    
    # 1. cgroup v2
    cg2 = _find_cgroup_dir("v2") or "/sys/fs/cgroup"
    cpu_max = _read_cgroup_file(f"{cg2}/cpu.max")
    if cpu_max:
        parts = cpu_max.split()
        if len(parts) == 2 and parts[0] != "max":
            try:
                quota = float(parts[0])
                period = float(parts[1])
                if period > 0:
                    effective = min(effective, quota / period)
            except Exception:
                pass
    
    cpuset_eff = _read_cgroup_file(f"{cg2}/cpuset.cpus.effective")
    if cpuset_eff:
        count = 0
        for segment in cpuset_eff.split(","):
            if "-" in segment:
                start, end = segment.split("-", 1)
                if start.isdigit() and end.isdigit():
                    count += (int(end) - int(start) + 1)
            elif segment.isdigit():
                count += 1
        if count > 0:
            effective = min(effective, float(count))
            
    # 2. cgroup v1 fallback
    cg1_cpu = _find_cgroup_dir("cpu") or "/sys/fs/cgroup/cpu"
    quota_v1 = _read_cgroup_file(f"{cg1_cpu}/cpu.cfs_quota_us")
    period_v1 = _read_cgroup_file(f"{cg1_cpu}/cpu.cfs_period_us")
    if quota_v1 and period_v1 and quota_v1.lstrip("-").isdigit() and period_v1.isdigit():
        q = int(quota_v1)
        p = int(period_v1)
        if q > 0 and p > 0:
            effective = min(effective, float(q) / float(p))
            
    return round(max(0.1, effective), 2), visible_cpus


def get_effective_ram() -> Tuple[int, int, int]:
    """Returns (effective_total_bytes, visible_total_bytes, ram_used_bytes)."""
    visible_total = 0
    visible_avail = 0
    
    proc_meminfo = Path("/proc/meminfo")
    if proc_meminfo.is_file():
        try:
            for line in proc_meminfo.read_text().splitlines():
                if line.startswith("MemTotal:"):
                    visible_total = int(line.split()[1]) * 1024
                elif line.startswith("MemAvailable:"):
                    visible_avail = int(line.split()[1]) * 1024
        except Exception:
            pass
            
    if visible_total == 0:
        visible_total = 1024 * 1024 * 1024  # default 1GB
        
    effective_total = visible_total
    used_bytes = max(0, visible_total - visible_avail)
    
    # 1. cgroup v2
    cg2 = _find_cgroup_dir("v2") or "/sys/fs/cgroup"
    mem_max = _read_cgroup_file(f"{cg2}/memory.max")
    mem_curr = _read_cgroup_file(f"{cg2}/memory.current")
    if mem_max and mem_max != "max" and mem_max.isdigit():
        val = int(mem_max)
        if val > 0 and val < 1152921504606846976:  # finite limit
            effective_total = min(effective_total, val)
    if mem_curr and mem_curr.isdigit():
        used_bytes = int(mem_curr)
        
    # 2. cgroup v1 fallback
    cg1_mem = _find_cgroup_dir("memory") or "/sys/fs/cgroup/memory"
    mem_v1 = _read_cgroup_file(f"{cg1_mem}/memory.limit_in_bytes")
    curr_v1 = _read_cgroup_file(f"{cg1_mem}/memory.usage_in_bytes")
    if mem_v1 and mem_v1.isdigit():
        val = int(mem_v1)
        if val > 0 and val < 1152921504606846976:
            effective_total = min(effective_total, val)
    if curr_v1 and curr_v1.isdigit():
        used_bytes = int(curr_v1)
        
    return effective_total, visible_total, used_bytes


def get_disk_resources(directory: Optional[str] = None) -> Tuple[int, int, bool]:
    """Returns (disk_total_bytes, disk_free_bytes, is_overlay)."""
    target = directory or os.environ.get("DOWNLOAD_DIR") or os.path.expanduser("~")
    try:
        usage = shutil.disk_usage(target)
        total = usage.total
        free = usage.free
    except Exception:
        total = 0
        free = 0
        
    is_overlay = False
    proc_mounts = Path("/proc/self/mountinfo")
    if proc_mounts.is_file():
        try:
            for line in proc_mounts.read_text().splitlines():
                if "overlay" in line:
                    is_overlay = True
                    break
        except Exception:
            pass
            
    return total, free, is_overlay


def detect_capabilities() -> Dict[str, Any]:
    """Detects hypervisor, container, root, desktop, and container tooling."""
    caps = {}
    caps["systemd"] = os.path.isdir("/run/systemd/system")
    caps["kvm"] = os.path.exists("/dev/kvm") and os.access("/dev/kvm", os.R_OK | os.W_OK)
    caps["docker"] = shutil.which("docker") is not None
    caps["aria2c"] = shutil.which("aria2c") is not None
    caps["curl"] = shutil.which("curl") is not None
    
    # Check container indicators
    caps["is_container"] = (
        os.path.exists("/.dockerenv") or
        os.path.exists("/run/.containerenv") or
        "docker" in (_read_cgroup_file("/proc/1/cgroup") or "") or
        "lxc" in (_read_cgroup_file("/proc/1/cgroup") or "")
    )
    
    # Check privilege mode
    is_root = (os.geteuid() == 0) if hasattr(os, "geteuid") else False
    if is_root:
        caps["privilege_mode"] = "CONTAINER_ROOT" if caps["is_container"] else "ROOT"
    else:
        # Check sudo authorized
        has_sudo = False
        try:
            res = subprocess.run(["sudo", "-n", "true"], capture_output=True, timeout=2)
            has_sudo = (res.returncode == 0)
        except Exception:
            pass
        caps["privilege_mode"] = "SUDO_AUTHORIZED" if has_sudo else "ROOTLESS"
        
    return caps


def collect_effective_metrics(download_dir: Optional[str] = None) -> Dict[str, Any]:
    """Collects comprehensive real-time system metrics."""
    eff_cpu, vis_cpu = get_effective_cpu()
    eff_ram, vis_ram, ram_used = get_effective_ram()
    disk_total, disk_free, is_overlay = get_disk_resources(download_dir)
    caps = detect_capabilities()
    
    return {
        "effective_cpu": eff_cpu,
        "visible_cpu": vis_cpu,
        "effective_ram_bytes": eff_ram,
        "visible_ram_bytes": vis_ram,
        "ram_used_bytes": ram_used,
        "disk_total_bytes": disk_total,
        "disk_free_bytes": disk_free,
        "is_overlay": is_overlay,
        "capabilities": caps,
        "privilege_mode": caps.get("privilege_mode", "ROOTLESS"),
    }
