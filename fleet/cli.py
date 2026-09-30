"""
CyberFleet and CyberTransfer unified CLI interface.
Called by cybervps.sh dispatch or directly via python -m fleet.cli.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import sys
import time
from typing import Optional
import urllib.error
import urllib.parse
import urllib.request

from fleet.agent import FleetAgent, get_agent_config_path, get_agent_download_dir
from fleet.database import FleetDatabase, get_default_db_path
from fleet.models import JobStatus, NodeStatus


def print_header(title: str):
    print(f"\n\033[1;36m=== {title} ===\033[0m\n")


def print_ok(msg: str):
    print(f"\033[1;32m[✓]\033[0m {msg}")


def print_warn(msg: str):
    print(f"\033[1;33m[!]\033[0m {msg}")


def print_fail(msg: str):
    print(f"\033[1;31m[✗]\033[0m {msg}")


def handle_fleet_cli(argv: list) -> int:
    parser = argparse.ArgumentParser(prog="cybervps fleet", description="CyberFleet Cluster Management")
    subparsers = parser.add_subparsers(dest="fleet_action")

    # status
    subparsers.add_parser("status")

    # nodes
    subparsers.add_parser("nodes")

    # join
    join_p = subparsers.add_parser("join")
    join_p.add_argument("controller_url", nargs="?", help="Controller URL")
    join_p.add_argument("enrollment_token", nargs="?", help="Enrollment token")
    join_p.add_argument("--name", help="Custom node name")

    # leave
    subparsers.add_parser("leave")

    # doctor
    subparsers.add_parser("doctor")

    # benchmark
    bm_p = subparsers.add_parser("benchmark")
    bm_p.add_argument("node", nargs="?", help="Node ID or name")

    # logs
    log_p = subparsers.add_parser("logs")
    log_p.add_argument("-n", "--lines", type=int, default=30)

    # start-controller
    ctrl_p = subparsers.add_parser("controller")
    ctrl_p.add_argument("--host", default="0.0.0.0")
    ctrl_p.add_argument("--port", type=int, default=8000)

    # start-agent
    subparsers.add_parser("agent")

    args = parser.parse_args(argv)

    if args.fleet_action == "status":
        db = FleetDatabase()
        nodes = db.list_nodes()
        agent = FleetAgent()
        print_header("CyberFleet Status")
        print(f"Controller DB:   {db.db_path} ({'Active' if db.db_path.exists() else 'Not initialized'})")
        print(f"Enrolled Nodes:  {len(nodes)} registered")
        
        cfg = agent.config
        if cfg.get("node_id"):
            print(f"Local Node Role: AGENT ENROLLED (ID: {cfg.get('node_id')}, Name: {cfg.get('node_name')})")
            print(f"Controller URL:  {cfg.get('controller_url')}")
        else:
            print("Local Node Role: CONTROLLER / STANDALONE (Not enrolled as agent)")
        return 0

    elif args.fleet_action == "nodes":
        db = FleetDatabase()
        nodes = db.list_nodes()
        print_header("CyberFleet Enrolled Nodes")
        if not nodes:
            print("No nodes registered in fleet.")
            return 0
        print(f"{'NAME':<16} {'STATUS':<10} {'PRIVILEGE':<14} {'EFFECTIVE CPU':<14} {'RAM (MB)':<12} {'DISK FREE':<12}")
        print("-" * 80)
        for n in nodes:
            eff_cpu = f"{n.get('effective_cpu', 1.0):.1f} vCPU"
            eff_ram = str(n.get("effective_ram_bytes", 0) // (1024**2))
            disk_free = f"{n.get('disk_free_bytes', 0) // (1024**3)} GB"
            print(f"{n['name']:<16} {n['status']:<10} {n.get('privilege_mode', 'ROOTLESS'):<14} {eff_cpu:<14} {eff_ram:<12} {disk_free:<12}")
        return 0

    elif args.fleet_action == "join":
        agent = FleetAgent()
        url = args.controller_url
        token = args.enrollment_token
        node_name = args.name

        if not url:
            try:
                url = input("Controller URL (e.g. http://1.2.3.4:8000): ").strip()
            except EOFError:
                pass
        if not token:
            try:
                token = input("Enrollment Token: ").strip()
            except EOFError:
                pass
        if not node_name and not args.name:
            try:
                node_name = input("Optional Node Name (default hostname): ").strip() or None
            except EOFError:
                pass

        if not url or not token:
            print_fail("Controller URL and Enrollment Token are required.")
            return 1

        success = agent.enroll(controller_url=url, enrollment_token=token, node_name=node_name)
        return 0 if success else 1

    elif args.fleet_action == "leave":
        agent = FleetAgent()
        if agent.config_path.exists():
            agent.config_path.unlink()
            print_ok("Node credentials removed. Node left CyberFleet.")
        else:
            print_warn("Node was not enrolled.")
        return 0

    elif args.fleet_action == "doctor":
        return run_fleet_doctor()

    elif args.fleet_action == "benchmark":
        agent = FleetAgent()
        print("Executing live node benchmark...")
        res = agent.run_benchmark()
        print_ok(f"Benchmark results: Download: {res['download_mbps']:.1f} Mbps, Upload: {res['upload_mbps']:.1f} Mbps")
        return 0

    elif args.fleet_action == "logs":
        db = FleetDatabase()
        logs = db.get_audit_logs(limit=args.lines)
        print_header(f"CyberFleet Audit Logs (Last {args.lines})")
        for l in logs:
            ts = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(l["timestamp"]))
            print(f"[{ts}] [{l['actor']}] {l['action']} -> {l['target']} ({l['result']}) {l.get('detail', '')}")
        return 0

    elif args.fleet_action == "controller":
        from fleet.controller import run_controller
        print_ok(f"Starting CyberFleet Controller on {args.host}:{args.port}...")
        run_controller(host=args.host, port=args.port)
        return 0

    elif args.fleet_action == "agent":
        agent = FleetAgent()
        agent.start_daemon()
        return 0

    else:
        parser.print_help()
        return 0


def handle_transfer_cli(argv: list) -> int:
    parser = argparse.ArgumentParser(prog="cybervps transfer", description="CyberTransfer Management")
    subparsers = parser.add_subparsers(dest="transfer_action")

    # add
    add_p = subparsers.add_parser("add")
    add_p.add_argument("url", help="Download URL")
    add_p.add_argument("--node", help="Preferred node name or ID")

    # jobs
    subparsers.add_parser("jobs")

    # status
    stat_p = subparsers.add_parser("status")
    stat_p.add_argument("job_id", help="Job ID")

    # cancel
    canc_p = subparsers.add_parser("cancel")
    canc_p.add_argument("job_id", help="Job ID")

    # retry
    retry_p = subparsers.add_parser("retry")
    retry_p.add_argument("job_id", help="Job ID")

    # link
    link_p = subparsers.add_parser("link")
    link_p.add_argument("job_id", help="Job ID")

    args = parser.parse_args(argv)
    db = FleetDatabase()

    if args.transfer_action == "add":
        from fleet.controller import controller_create_job_internal
        print(f"Probing URL and checking SSRF safety for: {args.url}...")
        job, err = controller_create_job_internal(url=args.url, preferred_node=args.node)
        if err or not job:
            print_fail(f"Rejection: {err}")
            return 1
        print_ok(f"Job created successfully! (Job ID: {job.id})")
        print(f"   File:     {job.filename}")
        print(f"   Size:     {job.expected_size // (1024**2)} MB")
        print(f"   Node:     {job.node_id}")
        print(f"   Reason:   {job.selection_reason}")
        return 0

    elif args.transfer_action == "jobs":
        jobs = db.list_jobs(limit=25)
        print_header("CyberTransfer Recent Jobs")
        if not jobs:
            print("No transfers found.")
            return 0
        print(f"{'ID':<14} {'STATUS':<12} {'FILENAME':<24} {'PROGRESS':<10} {'NODE':<14} {'SPEED':<12}")
        print("-" * 88)
        for j in jobs:
            pct = f"{j.progress_percent:.0f}%"
            speed = f"{j.current_speed_bps / (1024*1024):.1f} MB/s" if j.status == JobStatus.DOWNLOADING else "-"
            print(f"{j.id:<14} {j.status.value:<12} {j.filename[:22]:<24} {pct:<10} {(j.node_id or 'auto')[:12]:<14} {speed:<12}")
        return 0

    elif args.transfer_action == "status":
        job = db.get_job(args.job_id)
        if not job:
            print_fail(f"Job '{args.job_id}' not found.")
            return 1
        print_header(f"Job Status: {job.id}")
        print(f"Status:       {job.status.value}")
        print(f"URL:          {job.requested_url}")
        print(f"Filename:     {job.filename}")
        print(f"Size:         {job.downloaded_bytes // (1024**2)} / {job.expected_size // (1024**2)} MB ({job.progress_percent:.1f}%)")
        print(f"Node:         {job.node_id} ({job.selection_reason})")
        print(f"SHA256:       {job.sha256 or 'Pending'}")
        if job.failure_reason:
            print(f"Failure:      {job.failure_reason}")
        if job.signed_link_token:
            print(f"Direct Link:  /f/{job.signed_link_token}")
        return 0

    elif args.transfer_action == "cancel":
        job = db.get_job(args.job_id)
        if not job:
            print_fail(f"Job '{args.job_id}' not found.")
            return 1
        db.update_job_status(args.job_id, JobStatus.CANCELLED, "Cancelled via CLI")
        print_ok(f"Job '{args.job_id}' cancelled.")
        return 0

    elif args.transfer_action == "retry":
        job = db.get_job(args.job_id)
        if not job:
            print_fail(f"Job '{args.job_id}' not found.")
            return 1
        nodes = db.list_nodes()
        from fleet.scheduler import select_best_node
        best, reason = select_best_node(nodes=nodes, expected_size=job.expected_size)
        if not best:
            print_fail(f"No node available to retry: {reason}")
            return 1
        db.update_job_status(args.job_id, JobStatus.ASSIGNED)
        with db.connection() as conn:
            conn.execute("UPDATE jobs SET node_id = ?, selection_reason = ?, failure_reason = '', progress_percent = 0.0, downloaded_bytes = 0 WHERE id = ?", (best["id"], reason, args.job_id))
            conn.commit()
        print_ok(f"Job '{args.job_id}' rescheduled on node '{best['name']}'.")
        return 0

    elif args.transfer_action == "link":
        job = db.get_job(args.job_id)
        if not job:
            print_fail(f"Job '{args.job_id}' not found.")
            return 1
        if job.status != JobStatus.COMPLETED:
            print_warn(f"Job is {job.status.value}, not COMPLETED.")
            return 1
        print_header(f"Cybershare Link: {job.id}")
        if job.signed_link_token:
            print(f"Direct Token: {job.signed_link_token}")
            print(f"Expires:      {time.ctime(job.signed_link_expires_at)}")
        else:
            print("No direct link generated yet.")
        return 0

    else:
        parser.print_help()
        return 0


def run_fleet_doctor() -> int:
    print_header("CyberFleet Subsystem Doctor")
    overall_ok = True

    # 1. Controller DB check
    db = FleetDatabase()
    try:
        with db.connection() as conn:
            conn.execute("SELECT 1").fetchone()
        print_ok(f"Database: Operational ({db.db_path})")
    except Exception as e:
        print_fail(f"Database error: {e}")
        overall_ok = False

    # 2. Download directory
    dl_dir = get_agent_download_dir()
    if os.access(dl_dir, os.W_OK):
        usage = shutil.disk_usage(dl_dir)
        free_gb = usage.free / (1024**3)
        print_ok(f"Download Directory: Writable ({dl_dir}, {free_gb:.1f} GB free)")
    else:
        print_fail(f"Download Directory not writable: {dl_dir}")
        overall_ok = False

    # 3. aria2c / curl tooling
    has_aria = shutil.which("aria2c") is not None
    has_curl = shutil.which("curl") is not None
    if has_aria:
        print_ok("Downloader Tool: aria2c present (Multi-connection adaptive engine)")
    elif has_curl:
        print_warn("Downloader Tool: curl present (Fallback engine, aria2c recommended for multi-stream)")
    else:
        print_fail("Downloader Tool: Neither aria2c nor curl found in PATH")
        overall_ok = False

    # 4. DNS resolution
    try:
        socket.gethostbyname("api.github.com")
        print_ok("DNS Resolution: Operational")
    except Exception:
        print_warn("DNS Resolution: Failed to resolve external host")

    # 5. Telegram Configuration
    from fleet.telegram import get_telegram_config
    token, admins = get_telegram_config()
    if token:
        print_ok(f"Telegram Bot Token: Configured ({len(admins)} admin IDs authorized)")
    else:
        print_warn("Telegram Bot Token: Not configured (Optional)")

    # 6. Python FastAPI & Uvicorn
    try:
        import fastapi
        import uvicorn
        print_ok(f"Python ASGI Runtime: FastAPI v{fastapi.__version__}, Uvicorn present")
    except ImportError as e:
        print_fail(f"Python Dependencies Missing: {e}")
        overall_ok = False

    print("\n" + ("✔ All critical fleet components healthy." if overall_ok else "✖ Doctor detected issues."))
    return 0 if overall_ok else 1


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "fleet":
        sys.exit(handle_fleet_cli(sys.argv[2:]))
    elif len(sys.argv) > 1 and sys.argv[1] == "transfer":
        sys.exit(handle_transfer_cli(sys.argv[2:]))
    else:
        print("Usage: python3 -m fleet.cli {fleet|transfer} ...")
        sys.exit(1)


if __name__ == "__main__":
    main()
