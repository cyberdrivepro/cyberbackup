"""
CyberFleet Node Agent Daemon.
Outbound-only agent that maintains continuous heartbeat, tracks live network EMA,
polls for assigned transfer jobs, and runs the adaptive smart download engine.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import socket
import sys
import threading
import time
from typing import Any, Dict, Optional
import urllib.error
import urllib.request

from fleet.downloader import SmartDownloader, download_byte_range
from fleet.metrics import NetworkTrafficTracker, collect_effective_metrics


def get_agent_config_path() -> Path:
    config_home = os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))
    p = Path(config_home) / "cybervps" / "fleet" / "agent.json"
    p.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    return p


def get_agent_download_dir() -> Path:
    env_dir = os.environ.get("DOWNLOAD_DIR")
    if env_dir:
        p = Path(env_dir)
    else:
        p = Path.home() / "downloads" / "cybertransfer"
    p.mkdir(parents=True, exist_ok=True, mode=0o755)
    return p


class FleetAgent:
    def __init__(self, config_path: Optional[Path] = None):
        self.config_path = config_path or get_agent_config_path()
        self.config = self._load_config()
        self.download_dir = get_agent_download_dir()
        self.running = False
        self.traffic_tracker = NetworkTrafficTracker()
        self.active_jobs: Dict[str, threading.Thread] = {}
        self.active_chunks: Dict[str, threading.Thread] = {}
        self.cancel_events: Dict[str, threading.Event] = {}
        self.start_time = time.time()

    def _load_config(self) -> Dict[str, Any]:
        if not self.config_path.is_file():
            return {}
        try:
            return json.loads(self.config_path.read_text(encoding="utf-8"))
        except Exception:
            return {}

    def _save_config(self, cfg: Dict[str, Any]):
        self.config = cfg
        self.config_path.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
        if os.name != "nt":
            try:
                os.chmod(self.config_path, 0o600)
            except Exception:
                pass

    def enroll(self, controller_url: str, enrollment_token: str, node_name: Optional[str] = None) -> bool:
        """Enrolls this VPS with the Fleet Controller."""
        controller_url = controller_url.rstrip("/")
        enroll_endpoint = f"{controller_url}/api/v1/nodes/enroll"

        hostname = socket.gethostname()
        system_os = platform.system().lower()
        arch = platform.machine()
        metrics = collect_effective_metrics(str(self.download_dir))

        payload = {
            "enrollment_token": enrollment_token,
            "node_name": node_name or hostname,
            "hostname": hostname,
            "os": system_os,
            "arch": arch,
            "privilege_mode": metrics.get("privilege_mode", "ROOTLESS"),
            "environment": "container" if metrics["capabilities"].get("is_container") else "vps",
            "capabilities": metrics["capabilities"],
        }

        req = urllib.request.Request(
            enroll_endpoint,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json", "User-Agent": "CyberFleet-Agent/2.0"},
            method="POST",
        )

        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                if data.get("ok"):
                    self._save_config({
                        "node_id": data["node_id"],
                        "node_secret": data["node_secret"],
                        "controller_url": controller_url,
                        "node_name": node_name or hostname,
                        "enrolled_at": time.time(),
                    })
                    print(f"✔ Successfully enrolled into CyberFleet! (Node ID: {data['node_id']})")
                    return True
                else:
                    print(f"✖ Enrollment failed: {data.get('message')}", file=sys.stderr)
                    return False
        except Exception as e:
            print(f"✖ Connection error during enrollment: {e}", file=sys.stderr)
            return False

    def api_request(self, endpoint: str, data: Optional[Dict[str, Any]] = None, method: str = "GET") -> Optional[Dict[str, Any]]:
        """Makes an authenticated request to the Controller."""
        controller_url = self.config.get("controller_url", "").rstrip("/")
        node_id = self.config.get("node_id")
        node_secret = self.config.get("node_secret")

        if not controller_url or not node_id or not node_secret:
            return None

        url = f"{controller_url}{endpoint}"
        body = json.dumps(data).encode("utf-8") if data is not None else None
        headers = {
            "X-Node-ID": node_id,
            "X-Node-Secret": node_secret,
            "User-Agent": "CyberFleet-Agent/2.0",
        }
        if body is not None:
            headers["Content-Type"] = "application/json"

        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=12) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except Exception:
            return None

    def send_heartbeat(self):
        """Collects real effective metrics and submits heartbeat."""
        rx_bps, tx_bps = self.traffic_tracker.sample()
        metrics = collect_effective_metrics(str(self.download_dir))

        payload = {
            "node_id": self.config.get("node_id"),
            "timestamp": time.time(),
            "agent_version": "2.0.0",
            "hostname": socket.gethostname(),
            "os": platform.system().lower(),
            "arch": platform.machine(),
            "environment": "container" if metrics["capabilities"].get("is_container") else "vps",
            "privilege_mode": metrics.get("privilege_mode", "ROOTLESS"),
            "uptime_seconds": time.time() - self.start_time,
            "active_jobs_count": len(self.active_jobs) + len(self.active_chunks),
            "agent_status": "BUSY" if (self.active_jobs or self.active_chunks) else "IDLE",
            "effective_cpu": metrics["effective_cpu"],
            "visible_cpu": metrics["visible_cpu"],
            "effective_ram_bytes": metrics["effective_ram_bytes"],
            "visible_ram_bytes": metrics["visible_ram_bytes"],
            "ram_used_bytes": metrics["ram_used_bytes"],
            "disk_total_bytes": metrics["disk_total_bytes"],
            "disk_free_bytes": metrics["disk_free_bytes"],
            "live_rx_bps": rx_bps,
            "live_tx_bps": tx_bps,
            "capabilities": metrics["capabilities"],
        }

        self.api_request("/api/v1/agent/heartbeat", data=payload, method="POST")

    def poll_and_execute_jobs(self):
        """Polls controller for assigned transfer jobs."""
        resp = self.api_request("/api/v1/agent/jobs", method="GET")
        if not resp or not resp.get("ok"):
            return

        for job in resp.get("jobs", []):
            job_id = job["id"]
            if job_id not in self.active_jobs:
                t = threading.Thread(target=self._run_job_worker, args=(job,), daemon=True)
                self.active_jobs[job_id] = t
                t.start()

    def _run_job_worker(self, job: Dict[str, Any]):
        job_id = job["id"]
        url = job["requested_url"]
        filename = job.get("filename") or f"file_{job_id}.bin"
        expected_size = job.get("expected_size", 0)
        cancel_ev = threading.Event()
        self.cancel_events[job_id] = cancel_ev

        # Notify start
        self.api_request(f"/api/v1/agent/jobs/{job_id}/start", method="POST")

        last_progress_post = 0.0

        def progress_cb(downloaded: int, total: int, speed: float, eta: int):
            nonlocal last_progress_post
            now = time.time()
            if now - last_progress_post >= 1.0 or downloaded >= total:
                last_progress_post = now
                self.api_request(
                    f"/api/v1/agent/jobs/{job_id}/progress",
                    data={
                        "downloaded_bytes": downloaded,
                        "total_bytes": total,
                        "current_speed_bps": speed,
                        "eta_seconds": eta,
                    },
                    method="POST",
                )

        downloader = SmartDownloader(
            url=url,
            dest_dir=str(self.download_dir),
            filename=filename,
            expected_size=expected_size,
            accept_ranges=True,
            progress_callback=progress_cb,
            cancel_event=cancel_ev,
        )

        ok, final_path, sha256, downloaded_bytes, elapsed, err = downloader.download()

        if ok:
            self.api_request(
                f"/api/v1/agent/jobs/{job_id}/complete",
                data={
                    "sha256": sha256,
                    "size_bytes": downloaded_bytes,
                    "duration_seconds": elapsed,
                    "local_path": final_path,
                },
                method="POST",
            )
        else:
            self.api_request(
                f"/api/v1/agent/jobs/{job_id}/complete",
                data={
                    "sha256": "",
                    "size_bytes": 0,
                    "duration_seconds": elapsed,
                    "local_path": "",
                    "error": err or "Transfer failed",
                },
                method="POST",
            )

        if job_id in self.active_jobs:
            del self.active_jobs[job_id]
        if job_id in self.cancel_events:
            del self.cancel_events[job_id]

    def poll_and_execute_chunks(self):
        """Polls controller for assigned or pending BURST chunks."""
        resp = self.api_request("/api/v1/agent/chunks/poll", method="POST")
        if not resp or not resp.get("ok"):
            return

        chunk = resp.get("chunk")
        job_info = resp.get("job")
        if not chunk or not job_info:
            return

        chunk_id = chunk["id"]
        if chunk_id not in self.active_chunks:
            t = threading.Thread(target=self._run_chunk_worker, args=(chunk, job_info), daemon=True)
            self.active_chunks[chunk_id] = t
            t.start()

    def _run_chunk_worker(self, chunk: Dict[str, Any], job_info: Dict[str, Any]):
        chunk_id = chunk["id"]
        url = job_info.get("resolved_url") or job_info.get("url")
        start_byte = chunk["start_byte"]
        end_byte = chunk["end_byte"]
        expected_bytes = end_byte - start_byte + 1

        temp_chunk_path = self.download_dir / f"chunk_{chunk_id}.part"
        cancel_ev = threading.Event()
        self.cancel_events[chunk_id] = cancel_ev

        last_post = 0.0

        def chunk_prog_cb(downloaded: int, total: int, speed: float, eta: int):
            nonlocal last_post
            now = time.time()
            if now - last_post >= 1.0 or downloaded >= total:
                last_post = now
                self.api_request(
                    f"/api/v1/agent/chunks/{chunk_id}/progress",
                    data={
                        "downloaded_bytes": downloaded,
                        "total_bytes": total or expected_bytes,
                        "current_speed_bps": speed,
                        "eta_seconds": eta,
                    },
                    method="POST",
                )

        ok, chunk_sha256, downloaded_bytes, elapsed, err = download_byte_range(
            url=url,
            start_byte=start_byte,
            end_byte=end_byte,
            dest_path=temp_chunk_path,
            progress_callback=chunk_prog_cb,
            cancel_event=cancel_ev,
        )

        if ok and temp_chunk_path.exists():
            # If not assembler node, relay chunk file to controller relay
            assembler_node = job_info.get("assembler_node")
            my_node_id = self.config.get("node_id")
            if assembler_node and assembler_node != my_node_id:
                try:
                    controller_url = self.config.get("controller_url", "").rstrip("/")
                    relay_url = f"{controller_url}/api/v1/relay/chunks/{chunk_id}"
                    with open(temp_chunk_path, "rb") as f:
                        chunk_bytes = f.read()
                    req = urllib.request.Request(
                        relay_url,
                        data=chunk_bytes,
                        headers={
                            "X-Node-ID": my_node_id,
                            "X-Node-Secret": self.config.get("node_secret", ""),
                            "Content-Type": "application/octet-stream",
                            "User-Agent": "CyberFleet-Agent/2.0",
                        },
                        method="POST"
                    )
                    with urllib.request.urlopen(req, timeout=60):
                        pass
                except Exception:
                    pass

            self.api_request(
                f"/api/v1/agent/chunks/{chunk_id}/complete",
                data={
                    "sha256": chunk_sha256,
                    "size_bytes": downloaded_bytes,
                    "duration_seconds": elapsed,
                    "local_path": str(temp_chunk_path),
                },
                method="POST",
            )
        else:
            self.api_request(
                f"/api/v1/agent/chunks/{chunk_id}/fail",
                data={
                    "error": err or "Chunk download failed",
                    "can_retry": True,
                },
                method="POST",
            )

        if chunk_id in self.active_chunks:
            del self.active_chunks[chunk_id]
        if chunk_id in self.cancel_events:
            del self.cancel_events[chunk_id]

    def run_benchmark(self, provider: str = "internal", duration: float = 5.0) -> Dict[str, Any]:
        """Performs a brief network benchmark and posts results."""
        # Simple download benchmark from target CDN or test endpoint
        test_url = "https://speed.cloudflare.com/__down?bytes=25000000"  # 25 MB sample
        start = time.time()
        downloaded = 0
        try:
            req = urllib.request.Request(test_url, headers={"User-Agent": "CyberFleet-Benchmark/2.0"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                while True:
                    chunk = resp.read(65536)
                    if not chunk:
                        break
                    downloaded += len(chunk)
                    if time.time() - start >= duration:
                        break
        except Exception:
            pass

        elapsed = max(0.1, time.time() - start)
        dl_mbps = (downloaded * 8) / (elapsed * 1024 * 1024)
        ul_mbps = dl_mbps * 0.8  # Estimated upload ratio if asymmetric

        self.api_request(
            "/api/v1/agent/benchmark",
            data={
                "download_mbps": round(dl_mbps, 1),
                "upload_mbps": round(ul_mbps, 1),
                "provider": provider,
                "duration_seconds": round(elapsed, 1),
            },
            method="POST",
        )
        return {"download_mbps": dl_mbps, "upload_mbps": ul_mbps}

    def start_daemon(self):
        """Starts the persistent background agent loop."""
        if not self.config.get("node_id"):
            print("✖ Node is not enrolled. Run: cybervps fleet join <url> <token>", file=sys.stderr)
            return

        self.running = True
        print(f"🚀 CyberFleet Agent running (Node: {self.config.get('node_name')}, ID: {self.config.get('node_id')})")
        print(f"   Controller: {self.config.get('controller_url')}")
        print(f"   Storage:    {self.download_dir}")

        heartbeat_interval = float(os.environ.get("HEARTBEAT_INTERVAL", 5.0))
        last_heartbeat = 0.0

        while self.running:
            try:
                now = time.time()
                # 1. Heartbeat
                if now - last_heartbeat >= heartbeat_interval:
                    self.send_heartbeat()
                    last_heartbeat = now

                # 2. Check for assigned jobs
                self.poll_and_execute_jobs()

                # 3. Check for BURST chunks (work-stealing)
                self.poll_and_execute_chunks()

                time.sleep(1.5)
            except KeyboardInterrupt:
                print("\nStopping CyberFleet agent...")
                self.running = False
                break
            except Exception as e:
                time.sleep(3)


def main():
    parser = argparse.ArgumentParser(description="CyberFleet Node Agent")
    subparsers = parser.add_subparsers(dest="command")

    # join
    join_parser = subparsers.add_parser("join")
    join_parser.add_argument("controller_url", help="Controller URL (e.g. http://1.2.3.4:8000)")
    join_parser.add_argument("enrollment_token", help="Fleet enrollment token")
    join_parser.add_argument("--name", help="Optional friendly node name")

    # run
    subparsers.add_parser("run")

    # benchmark
    subparsers.add_parser("benchmark")

    # status
    subparsers.add_parser("status")

    args = parser.parse_args()
    agent = FleetAgent()

    if args.command == "join":
        success = agent.enroll(args.controller_url, args.enrollment_token, args.name)
        sys.exit(0 if success else 1)
    elif args.command == "run":
        agent.start_daemon()
    elif args.command == "benchmark":
        print("Running CyberFleet benchmark...")
        res = agent.run_benchmark()
        print(f"✔ Benchmark Results: Download: {res['download_mbps']:.1f} Mbps, Upload: {res['upload_mbps']:.1f} Mbps")
    elif args.command == "status":
        cfg = agent.config
        if not cfg.get("node_id"):
            print("Status: NOT_ENROLLED")
        else:
            print("Status: ENROLLED")
            print(f"Node Name:   {cfg.get('node_name')}")
            print(f"Node ID:     {cfg.get('node_id')}")
            print(f"Controller:  {cfg.get('controller_url')}")
            print(f"Storage Dir: {agent.download_dir}")
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
