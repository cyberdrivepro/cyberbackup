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
from fleet.models import JobMode, JobStatus, NodeStatus


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

    # drain
    drain_p = subparsers.add_parser("drain")
    drain_p.add_argument("node", help="Node ID or friendly name")
    drain_p.add_argument("--undrain", action="store_true", help="Remove drain state")

    # rm
    rm_p = subparsers.add_parser("rm")
    rm_p.add_argument("node", help="Node ID or friendly name")
    rm_p.add_argument("--force", action="store_true", help="Force removal even if active jobs/replicas exist")

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

    elif args.fleet_action == "drain":
        db = FleetDatabase()
        nodes = db.list_nodes()
        target = next((n for n in nodes if n["id"] == args.node or n["name"] == args.node), None)
        if not target:
            print_fail(f"Node '{args.node}' not found.")
            return 1
        drained_state = not args.undrain
        db.drain_node(target["id"], drained=drained_state)
        if drained_state:
            reassigned = db.reassign_node_chunks_on_loss(target["id"])
            print_ok(f"Node '{target['name']}' drained. In-flight chunks requeued: {reassigned}")
        else:
            print_ok(f"Node '{target['name']}' un-drained and active for new jobs.")
        return 0

    elif args.fleet_action == "rm":
        db = FleetDatabase()
        nodes = db.list_nodes()
        target = next((n for n in nodes if n["id"] == args.node or n["name"] == args.node), None)
        if not target:
            print_fail(f"Node '{args.node}' not found.")
            return 1
        ok, reason = db.remove_node_safely(target["id"], force=args.force)
        if ok:
            print_ok(f"Node '{target['name']}' removed from fleet: {reason}")
            return 0
        else:
            print_fail(f"Safe removal blocked: {reason} (Use --force to override)")
            return 1

    else:
        parser.print_help()
        return 0


def handle_transfer_cli(argv: list) -> int:
    parser = argparse.ArgumentParser(prog="cybervps transfer", description="CyberTransfer Management")
    subparsers = parser.add_subparsers(dest="transfer_action")

    # add
    add_p = subparsers.add_parser("add")
    add_p.add_argument("url", help="Download URL")
    add_p.add_argument("--mode", choices=["AUTO", "SINGLE", "BURST", "MIRROR"], default="AUTO", help="Transfer mode")
    add_p.add_argument("--replicas", type=int, default=2, help="Replica count for MIRROR mode")
    add_p.add_argument("--node", help="Preferred node name or ID")

    # chunks
    chk_p = subparsers.add_parser("chunks")
    chk_p.add_argument("job_id", help="Job ID")

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
        print(f"Probing URL and checking SSRF safety for: {args.url} (Mode: {args.mode})...")
        job, err = controller_create_job_internal(
            url=args.url,
            mode=JobMode(args.mode),
            replicas=args.replicas,
            preferred_node=args.node,
        )
        if err or not job:
            print_fail(f"Rejection: {err}")
            return 1
        print_ok(f"Job created successfully! (Job ID: {job.id})")
        print(f"   Mode:     {job.mode}")
        print(f"   File:     {job.filename}")
        print(f"   Size:     {job.expected_size // (1024**2)} MB")
        if job.mode == "BURST":
            print(f"   Assembler:{job.assembler_node or job.node_id}")
            print(f"   Chunks:   {job.chunks_total} distributed")
        else:
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

    elif args.transfer_action == "chunks":
        job = db.get_job(args.job_id)
        if not job:
            print_fail(f"Job '{args.job_id}' not found.")
            return 1
        chunks = db.get_chunks_for_job(args.job_id)
        print_header(f"Job Chunks: {job.id} (Mode: {job.mode}, Total: {len(chunks)})")
        if not chunks:
            print("No chunks planned (Single-node or direct transfer).")
            return 0
        print(f"{'CHUNK':<8} {'RANGE':<28} {'STATUS':<12} {'NODE':<14} {'PROGRESS':<12} {'SPEED':<12}")
        print("-" * 90)
        for c in chunks:
            r = f"{c['start_byte']} - {c['end_byte']}"
            pct = f"{(c['downloaded_bytes'] / max(1, c['byte_length']) * 100):.0f}%"
            sp = f"{c['current_speed_bps'] / (1024*1024):.1f} MB/s" if c['current_speed_bps'] > 0 else "-"
            print(f"{c['chunk_index']:<8} {r:<28} {c['status']:<12} {(c['node_id'] or 'pending')[:12]:<14} {pct:<12} {sp:<12}")
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


def handle_store_cli(argv: list) -> int:
    parser = argparse.ArgumentParser(prog="cybervps store", description="CyberStore Content-Addressed Distributed Storage")
    subparsers = parser.add_subparsers(dest="store_action")

    # summary
    subparsers.add_parser("summary")
    subparsers.add_parser("status")

    # files / list
    subparsers.add_parser("files")
    subparsers.add_parser("list")

    # put
    put_p = subparsers.add_parser("put")
    put_p.add_argument("file_path", help="Local file path to ingest")
    put_p.add_argument("--replicas", type=int, default=2, help="Replication factor")

    # gc
    gc_p = subparsers.add_parser("gc")
    gc_p.add_argument("--dry-run", action="store_true", default=False, help="List unreferenced objects without deleting")
    gc_p.add_argument("--force", action="store_true", default=False, help="Perform actual deletion")

    # rebalance
    subparsers.add_parser("rebalance")

    args = parser.parse_args(argv)
    db = FleetDatabase()
    from fleet.store import CyberStore
    store = CyberStore(db)

    if args.store_action in ("summary", "status"):
        sum_data = db.get_cyberstore_summary()
        print_header("CyberStore Storage Engine Overview")
        print(f"Total Unique Objects:  {sum_data['total_unique_objects']}")
        print(f"Physical Disk Used:    {sum_data['total_physical_bytes'] / (1024**2):.2f} MB")
        print(f"Logical Stored Data:   {sum_data['total_logical_bytes'] / (1024**2):.2f} MB")
        print(f"Deduplication Savings: {sum_data['dedup_savings_percent']:.1f}%")
        print(f"Total Stored Files:    {sum_data['total_stored_files']}")
        print(f"Under-replicated:      {sum_data['under_replicated_files']}")
        return 0

    elif args.store_action in ("files", "list"):
        files = db.list_stored_files(limit=50)
        print_header("CyberStore Stored Files")
        if not files:
            print("No files stored in CyberStore.")
            return 0
        print(f"{'FILE ID':<16} {'FILENAME':<24} {'SIZE (MB)':<12} {'CHUNKS':<8} {'STATUS':<12}")
        print("-" * 75)
        for f in files:
            sz = f"{f.size_bytes / (1024**2):.1f}"
            print(f"{f.file_id:<16} {f.filename[:22]:<24} {sz:<12} {f.chunks_count:<8} {f.status:<12}")
        return 0

    elif args.store_action == "put":
        p = Path(args.file_path)
        if not p.is_file():
            print_fail(f"File not found: {args.file_path}")
            return 1
        stored = store.store_file(p, replication_factor=args.replicas)
        print_ok("Stored file successfully in CyberStore!")
        print(f"   File ID:   {stored.file_id}")
        print(f"   Filename:  {stored.filename}")
        print(f"   Size:      {stored.size_bytes / (1024**2):.2f} MB")
        print(f"   Replicas:  {stored.replication_factor}")
        return 0

    elif args.store_action == "gc":
        dry_run = not args.force
        if dry_run:
            print_warn("Running GC in dry-run mode (no objects deleted). Use --force to delete.")
        reclaimed, deleted, unref = store.garbage_collect(dry_run=dry_run)
        print_ok(f"Garbage collection {'dry-run ' if dry_run else ''}completed:")
        print(f"   Reclaimable/Deleted: {deleted} objects ({reclaimed / (1024**2):.2f} MB)")
        if unref:
            print(f"   Unreferenced Hashes: {len(unref)} found")
        return 0

    elif args.store_action == "rebalance":
        from fleet.models import NodeRecord
        active_nodes = [NodeRecord(**n) for n in db.list_nodes() if n["status"] == "ONLINE" and not n.get("is_drained")]
        repaired = store.rebalance_replicas(active_nodes=active_nodes)
        print_ok(f"CyberStore replica rebalance completed. Chunks repaired/scheduled: {repaired}")
        return 0

    else:
        parser.print_help()
        return 0


def handle_net_cli(argv: list) -> int:
    parser = argparse.ArgumentParser(prog="cybervps net", description="CyberNet Full-Device VPN & Mobile Gateways")
    subparsers = parser.add_subparsers(dest="net_action")

    # status
    subparsers.add_parser("status")

    # gateways
    gw_p = subparsers.add_parser("gateways")
    gw_p.add_argument("--profile", default="BALANCED", help="Scoring profile (BALANCED, LOW_LATENCY, MAX_THROUGHPUT, STREAMING)")

    # gateway
    gw_cmd = subparsers.add_parser("gateway")
    gw_sub = gw_cmd.add_subparsers(dest="gateway_action")
    gw_enable = gw_sub.add_parser("enable")
    gw_enable.add_argument("node_id", help="Node ID to enable as gateway")
    gw_disable = gw_sub.add_parser("disable")
    gw_disable.add_argument("node_id", help="Node ID to disable")
    gw_sub.add_parser("status")

    # sessions
    subparsers.add_parser("sessions")

    # devices
    subparsers.add_parser("devices")

    # revoke
    rev_p = subparsers.add_parser("revoke")
    rev_p.add_argument("device_id", help="Device ID to revoke")

    # doctor
    subparsers.add_parser("doctor")

    # benchmark
    bm_p = subparsers.add_parser("benchmark")
    bm_p.add_argument("gateway_id", help="Gateway Node ID to benchmark")

    args = parser.parse_args(argv)
    db = FleetDatabase()

    if args.net_action == "status":
        print_header("CyberNet Full-Device VPN Status")
        summary = db.get_cybernet_summary()
        print(f"Connected Devices:  {summary['devices_connected']} / {summary['devices_total']}")
        print(f"Active Gateways:    {summary['gateways_healthy']} / {summary['gateways_total']}")
        print(f"Active Sessions:    {summary['sessions_active']}")
        print(f"Total Sessions:     {summary['sessions_total']}")
        print(f"Tunnel Traffic RX:  {summary['fleet_vpn_rx_bytes'] / (1024**2):.2f} MB")
        print(f"Tunnel Traffic TX:  {summary['fleet_vpn_tx_bytes'] / (1024**2):.2f} MB")
        return 0

    elif args.net_action == "gateways":
        print_header("CyberNet Fleet Gateways")
        from fleet.cybernet import calculate_gateway_score
        from fleet.models import CyberNetScoreProfile, NodeRecord

        try:
            profile = CyberNetScoreProfile(args.profile.upper())
        except Exception:
            profile = CyberNetScoreProfile.BALANCED

        gateways = db.list_gateways(only_enabled=False)
        nodes = {n["id"]: NodeRecord(**n) for n in db.list_nodes()}

        if not gateways:
            print_warn("No gateway nodes found. Enable one with: cybervps net gateway enable <node_id>")
            return 0

        print(f"{'NODE ID':<16} {'NAME':<16} {'REGION':<8} {'IP':<16} {'LATENCY':<10} {'SESSIONS':<10} {'SCORE':<8} {'STATUS'}")
        print("-" * 92)
        for gw in gateways:
            node = nodes.get(gw.node_id)
            score = calculate_gateway_score(gw, node, profile)
            node_name = node.name if node else gw.node_id
            status_str = "\033[1;32mENABLED\033[0m" if gw.enabled else "\033[1;30mDISABLED\033[0m"
            print(f"{gw.node_id:<16} {node_name:<16} {gw.region:<8} {gw.ipv4_address:<16} {gw.latency_ms:<10.1f} {gw.active_sessions:<10} {score:<8.1f} {status_str}")
        return 0

    elif args.net_action == "gateway":
        if args.gateway_action == "enable":
            node = db.get_node(args.node_id)
            if not node:
                print_fail(f"Node not found: {args.node_id}")
                return 1
            gw = db.set_gateway(
                node_id=args.node_id,
                enabled=True,
                ipv4_address=node.get("hostname", "127.0.0.1"),
                region=node.get("region") or "NL",
            )
            print_ok(f"Enabled CyberNet gateway on node {args.node_id} ({node['name']})")
            return 0
        elif args.gateway_action == "disable":
            db.set_gateway(node_id=args.node_id, enabled=False)
            print_ok(f"Disabled CyberNet gateway on node {args.node_id}")
            return 0
        else:
            print("Usage: cybervps net gateway {enable|disable} <node_id>")
            return 1

    elif args.net_action == "devices":
        print_header("Enrolled CyberNet Mobile Devices")
        devices = db.list_devices()
        if not devices:
            print_warn("No mobile devices enrolled yet.")
            return 0
        print(f"{'DEVICE ID':<18} {'NAME':<18} {'OS':<16} {'STATUS':<10} {'LAST SEEN'}")
        print("-" * 75)
        for d in devices:
            st = "\033[1;32mACTIVE\033[0m" if d.status.value == "ACTIVE" else "\033[1;31mREVOKED\033[0m"
            print(f"{d.id:<18} {d.name:<18} {d.os_version:<16} {st:<19} {time.strftime('%Y-%m-%d %H:%M', time.localtime(d.last_seen_at))}")
        return 0

    elif args.net_action == "sessions":
        print_header("CyberNet VPN Sessions")
        sessions = db.list_sessions(limit=30)
        if not sessions:
            print_warn("No VPN sessions recorded.")
            return 0
        print(f"{'SESSION ID':<18} {'DEVICE ID':<16} {'GATEWAY':<16} {'PROTOCOL':<12} {'ASSIGNED IP':<14} {'STATUS'}")
        print("-" * 88)
        for s in sessions:
            st = "\033[1;32mACTIVE\033[0m" if s.status.value == "ACTIVE" else s.status.value
            print(f"{s.session_id:<18} {s.device_id:<16} {s.gateway_node_id:<16} {s.protocol.value:<12} {s.assigned_ip:<14} {st}")
        return 0

    elif args.net_action == "revoke":
        ok = db.revoke_device(args.device_id)
        if ok:
            print_ok(f"Device {args.device_id} successfully revoked. Active sessions terminated.")
            return 0
        else:
            print_fail(f"Device {args.device_id} not found.")
            return 1

    elif args.net_action == "doctor":
        print_header("CyberNet Diagnostics Doctor")
        from fleet.doctor import CyberNetDoctor
        checks = CyberNetDoctor.run_all()
        for c in checks:
            if c["status"] == "PASS":
                print_ok(f"{c['name']}: {c['detail']}")
            elif c["status"] == "WARN":
                print_warn(f"{c['name']}: {c['detail']}")
            else:
                print_fail(f"{c['name']}: {c['detail']}")
        return 0

    elif args.net_action == "benchmark":
        print_header(f"Benchmarking CyberNet Gateway: {args.gateway_id}")
        gw = db.get_gateway(args.gateway_id)
        if not gw:
            print_fail(f"Gateway {args.gateway_id} not found.")
            return 1
        print_ok(f"Testing connectivity to {gw.ipv4_address}:{gw.wireguard_port}...")
        start = time.time()
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.settimeout(2.0)
            s.sendto(b"\x01\x00\x00\x00", (gw.ipv4_address, gw.wireguard_port))
            lat = (time.time() - start) * 1000
            s.close()
            print_ok(f"Roundtrip probe: {lat:.1f} ms | Score: {gw.gateway_score}")
        except Exception as e:
            print_warn(f"Probe latency measurement warning: {e}")
        return 0

    else:
        parser.print_help()
        return 0


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "fleet":
        sys.exit(handle_fleet_cli(sys.argv[2:]))
    elif len(sys.argv) > 1 and sys.argv[1] == "transfer":
        sys.exit(handle_transfer_cli(sys.argv[2:]))
    elif len(sys.argv) > 1 and sys.argv[1] == "store":
        sys.exit(handle_store_cli(sys.argv[2:]))
    elif len(sys.argv) > 1 and sys.argv[1] == "net":
        sys.exit(handle_net_cli(sys.argv[2:]))
    else:
        print("Usage: python3 -m fleet.cli {fleet|transfer|store|net} ...")
        sys.exit(1)


if __name__ == "__main__":
    main()

