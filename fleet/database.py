"""
SQLite database persistence engine for CyberFleet Controller.
Thread-safe, WAL enabled, 0600 permissions, auto-migrating schema.
"""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import secrets
import sqlite3
import time
from typing import Any, Dict, List, Optional
from fleet.models import (
    JobRecord, JobStatus, JobMode, NodeRecord, NodeStatus,
    DownloadChunk, ChunkStatus, TransferTicket,
    StorageObject, StorageReplica, StoredFile, StoredFileChunk,
    CyberNetDevice, CyberNetGatewayInfo, CyberNetSessionRecord,
    CyberNetDeviceStatus, CyberNetSessionStatus, CyberNetProtocol,
)


def get_default_db_path() -> Path:
    env_path = os.environ.get("CYBERFLEET_DB_PATH")
    if env_path:
        p = Path(env_path)
    else:
        state_home = os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))
        p = Path(state_home) / "cybervps" / "fleet" / "fleet.db"
    p.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    return p


class FleetDatabase:
    def __init__(self, db_path: Optional[Path] = None):
        self.db_path = db_path or get_default_db_path()
        self._init_schema()

    @contextmanager
    def connection(self):
        conn = sqlite3.connect(str(self.db_path), timeout=20.0)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON;")
        conn.execute("PRAGMA journal_mode = WAL;")
        conn.execute("PRAGMA busy_timeout = 10000;")
        try:
            if os.name != "nt" and self.db_path.exists():
                try:
                    os.chmod(self.db_path, 0o600)
                except Exception:
                    pass
            yield conn
        finally:
            conn.close()

    def _init_schema(self):
        with self.connection() as conn:
            conn.executescript("""
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS users (
                id TEXT PRIMARY KEY,
                username TEXT UNIQUE NOT NULL,
                password_hash TEXT NOT NULL,
                role TEXT NOT NULL DEFAULT 'admin',
                created_at REAL NOT NULL,
                last_login REAL
            );

            CREATE TABLE IF NOT EXISTS nodes (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                secret_hash TEXT NOT NULL,
                hostname TEXT NOT NULL DEFAULT 'unknown',
                os TEXT NOT NULL DEFAULT 'linux',
                arch TEXT NOT NULL DEFAULT 'x86_64',
                privilege_mode TEXT NOT NULL DEFAULT 'ROOTLESS',
                environment TEXT NOT NULL DEFAULT 'vps',
                status TEXT NOT NULL DEFAULT 'ONLINE',
                agent_version TEXT NOT NULL DEFAULT '2.0.0',
                enrolled_at REAL NOT NULL,
                last_heartbeat REAL NOT NULL,
                effective_cpu REAL NOT NULL DEFAULT 1.0,
                visible_cpu INTEGER NOT NULL DEFAULT 1,
                effective_ram_bytes INTEGER NOT NULL DEFAULT 0,
                visible_ram_bytes INTEGER NOT NULL DEFAULT 0,
                ram_used_bytes INTEGER NOT NULL DEFAULT 0,
                disk_total_bytes INTEGER NOT NULL DEFAULT 0,
                disk_free_bytes INTEGER NOT NULL DEFAULT 0,
                live_rx_bps REAL NOT NULL DEFAULT 0.0,
                live_tx_bps REAL NOT NULL DEFAULT 0.0,
                last_benchmark_dl_bps REAL NOT NULL DEFAULT 0.0,
                last_benchmark_ul_bps REAL NOT NULL DEFAULT 0.0,
                benchmark_timestamp REAL NOT NULL DEFAULT 0.0,
                recent_avg_speed_bps REAL NOT NULL DEFAULT 0.0,
                recent_peak_speed_bps REAL NOT NULL DEFAULT 0.0,
                total_bytes_transferred INTEGER NOT NULL DEFAULT 0,
                active_jobs_count INTEGER NOT NULL DEFAULT 0,
                reliability_score REAL NOT NULL DEFAULT 100.0,
                failure_count INTEGER NOT NULL DEFAULT 0,
                success_count INTEGER NOT NULL DEFAULT 0,
                capabilities_json TEXT NOT NULL DEFAULT '{}',
                region TEXT
            );

            CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY,
                requested_url TEXT NOT NULL,
                resolved_url TEXT NOT NULL DEFAULT '',
                filename TEXT NOT NULL DEFAULT '',
                content_type TEXT NOT NULL DEFAULT 'application/octet-stream',
                expected_size INTEGER NOT NULL DEFAULT 0,
                downloaded_bytes INTEGER NOT NULL DEFAULT 0,
                progress_percent REAL NOT NULL DEFAULT 0.0,
                current_speed_bps REAL NOT NULL DEFAULT 0.0,
                peak_speed_bps REAL NOT NULL DEFAULT 0.0,
                average_speed_bps REAL NOT NULL DEFAULT 0.0,
                eta_seconds INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL DEFAULT 'QUEUED',
                node_id TEXT,
                selection_reason TEXT NOT NULL DEFAULT '',
                sha256 TEXT NOT NULL DEFAULT '',
                local_path TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                started_at REAL NOT NULL DEFAULT 0.0,
                completed_at REAL NOT NULL DEFAULT 0.0,
                retry_count INTEGER NOT NULL DEFAULT 0,
                max_retries INTEGER NOT NULL DEFAULT 3,
                failure_reason TEXT NOT NULL DEFAULT '',
                telegram_chat_id INTEGER,
                telegram_message_id INTEGER,
                telegram_delivered INTEGER NOT NULL DEFAULT 0,
                signed_link_token TEXT NOT NULL DEFAULT '',
                signed_link_expires_at REAL NOT NULL DEFAULT 0.0
            );

            CREATE TABLE IF NOT EXISTS signed_links (
                token TEXT PRIMARY KEY,
                job_id TEXT NOT NULL,
                file_path TEXT NOT NULL,
                filename TEXT NOT NULL,
                file_size INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                expires_at REAL NOT NULL,
                downloads_count INTEGER NOT NULL DEFAULT 0,
                max_downloads INTEGER NOT NULL DEFAULT 0,
                revoked INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS audit_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp REAL NOT NULL,
                actor TEXT NOT NULL,
                action TEXT NOT NULL,
                target TEXT NOT NULL,
                result TEXT NOT NULL,
                detail TEXT NOT NULL DEFAULT ''
            );

            CREATE TABLE IF NOT EXISTS chunks (
                chunk_id TEXT PRIMARY KEY,
                job_id TEXT NOT NULL,
                chunk_index INTEGER NOT NULL,
                start_byte INTEGER NOT NULL,
                end_byte INTEGER NOT NULL,
                expected_length INTEGER NOT NULL,
                downloaded_bytes INTEGER NOT NULL DEFAULT 0,
                node_id TEXT,
                status TEXT NOT NULL DEFAULT 'PENDING',
                attempt_count INTEGER NOT NULL DEFAULT 0,
                checksum TEXT NOT NULL DEFAULT '',
                speed_bps REAL NOT NULL DEFAULT 0.0,
                created_at REAL NOT NULL,
                started_at REAL NOT NULL DEFAULT 0.0,
                completed_at REAL NOT NULL DEFAULT 0.0,
                local_path TEXT NOT NULL DEFAULT '',
                FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS transfer_tickets (
                ticket_id TEXT PRIMARY KEY,
                job_id TEXT NOT NULL,
                chunk_id TEXT NOT NULL,
                source_node TEXT NOT NULL,
                destination_node TEXT NOT NULL,
                expires_at REAL NOT NULL,
                nonce TEXT NOT NULL,
                signature TEXT NOT NULL,
                used INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS storage_objects (
                object_hash TEXT PRIMARY KEY,
                size_bytes INTEGER NOT NULL,
                reference_count INTEGER NOT NULL DEFAULT 1,
                created_at REAL NOT NULL,
                last_accessed_at REAL NOT NULL,
                pinned INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS storage_replicas (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                object_hash TEXT NOT NULL,
                node_id TEXT NOT NULL,
                local_rel_path TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                is_healthy INTEGER NOT NULL DEFAULT 1,
                stored_at REAL NOT NULL,
                UNIQUE(object_hash, node_id),
                FOREIGN KEY (object_hash) REFERENCES storage_objects(object_hash) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS stored_files (
                file_id TEXT PRIMARY KEY,
                filename TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                final_hash TEXT NOT NULL,
                replication_factor INTEGER NOT NULL DEFAULT 2,
                created_at REAL NOT NULL,
                status TEXT NOT NULL DEFAULT 'HEALTHY'
            );

            CREATE TABLE IF NOT EXISTS stored_file_chunks (
                file_id TEXT NOT NULL,
                chunk_index INTEGER NOT NULL,
                object_hash TEXT NOT NULL,
                start_byte INTEGER NOT NULL,
                end_byte INTEGER NOT NULL,
                PRIMARY KEY (file_id, chunk_index),
                FOREIGN KEY (file_id) REFERENCES stored_files(file_id) ON DELETE CASCADE,
                FOREIGN KEY (object_hash) REFERENCES storage_objects(object_hash)
            );

            CREATE TABLE IF NOT EXISTS cybernet_devices (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                device_type TEXT NOT NULL DEFAULT 'android',
                os_version TEXT NOT NULL DEFAULT 'Android 15',
                public_key TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'ACTIVE',
                enrolled_at REAL NOT NULL,
                last_seen_at REAL NOT NULL,
                auth_token_hash TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS cybernet_gateways (
                node_id TEXT PRIMARY KEY,
                enabled INTEGER NOT NULL DEFAULT 1,
                wireguard_enabled INTEGER NOT NULL DEFAULT 1,
                wireguard_port INTEGER NOT NULL DEFAULT 51820,
                wireguard_public_key TEXT NOT NULL DEFAULT '',
                wireguard_subnet TEXT NOT NULL DEFAULT '10.66.0.0/24',
                wireguard_status TEXT NOT NULL DEFAULT 'READY',
                wireguard_status_detail TEXT NOT NULL DEFAULT '',
                userspace_fallback_ready INTEGER NOT NULL DEFAULT 1,
                wireguard_private_key TEXT,
                ssh_enabled INTEGER NOT NULL DEFAULT 1,
                ssh_port INTEGER NOT NULL DEFAULT 22,
                udp_supported INTEGER NOT NULL DEFAULT 1,
                ipv4_address TEXT NOT NULL DEFAULT '',
                ipv6_address TEXT,
                region TEXT NOT NULL DEFAULT 'NL',
                latency_ms REAL NOT NULL DEFAULT 0.0,
                packet_loss REAL NOT NULL DEFAULT 0.0,
                active_sessions INTEGER NOT NULL DEFAULT 0,
                tunnel_rx_bytes INTEGER NOT NULL DEFAULT 0,
                tunnel_tx_bytes INTEGER NOT NULL DEFAULT 0,
                gateway_score REAL NOT NULL DEFAULT 0.0,
                FOREIGN KEY (node_id) REFERENCES nodes(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS cybernet_enroll_tokens (
                token TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                expires_at REAL NOT NULL,
                used INTEGER NOT NULL DEFAULT 0,
                created_by TEXT NOT NULL DEFAULT 'admin'
            );

            CREATE TABLE IF NOT EXISTS cybernet_sessions (
                session_id TEXT PRIMARY KEY,
                device_id TEXT NOT NULL,
                gateway_node_id TEXT NOT NULL,
                protocol TEXT NOT NULL DEFAULT 'WIREGUARD',
                assigned_ip TEXT NOT NULL DEFAULT '10.66.0.2',
                start_time REAL NOT NULL,
                end_time REAL,
                status TEXT NOT NULL DEFAULT 'ACTIVE',
                bytes_rx INTEGER NOT NULL DEFAULT 0,
                bytes_tx INTEGER NOT NULL DEFAULT 0,
                disconnect_reason TEXT,
                FOREIGN KEY (device_id) REFERENCES cybernet_devices(id),
                FOREIGN KEY (gateway_node_id) REFERENCES nodes(id)
            );

            CREATE INDEX IF NOT EXISTS idx_nodes_status ON nodes(status);
            CREATE INDEX IF NOT EXISTS idx_jobs_status ON jobs(status);
            CREATE INDEX IF NOT EXISTS idx_jobs_created_at ON jobs(created_at);
            CREATE INDEX IF NOT EXISTS idx_signed_links_expires ON signed_links(expires_at);
            CREATE INDEX IF NOT EXISTS idx_chunks_job ON chunks(job_id);
            CREATE INDEX IF NOT EXISTS idx_chunks_status ON chunks(status);
            CREATE INDEX IF NOT EXISTS idx_chunks_node ON chunks(node_id);
            CREATE INDEX IF NOT EXISTS idx_storage_replicas_node ON storage_replicas(node_id);
            CREATE INDEX IF NOT EXISTS idx_storage_replicas_hash ON storage_replicas(object_hash);
            CREATE INDEX IF NOT EXISTS idx_cybernet_devices_status ON cybernet_devices(status);
            CREATE INDEX IF NOT EXISTS idx_cybernet_sessions_device ON cybernet_sessions(device_id);
            CREATE INDEX IF NOT EXISTS idx_cybernet_sessions_status ON cybernet_sessions(status);
            CREATE INDEX IF NOT EXISTS idx_cybernet_sessions_gateway ON cybernet_sessions(gateway_node_id);
            """)

            # Column migrations for existing databases
            job_cols = {
                "mode": "TEXT NOT NULL DEFAULT 'SINGLE'",
                "assembler_node": "TEXT",
                "chunks_total": "INTEGER NOT NULL DEFAULT 0",
                "chunks_completed": "INTEGER NOT NULL DEFAULT 0",
                "transfer_path": "TEXT NOT NULL DEFAULT 'DIRECT'",
                "fleet_speed_bps": "REAL NOT NULL DEFAULT 0.0",
                "worker_nodes_json": "TEXT NOT NULL DEFAULT '[]'",
                "replicas": "INTEGER NOT NULL DEFAULT 1",
            }
            existing_cols = {row[1] for row in conn.execute("PRAGMA table_info(jobs)").fetchall()}
            for col, col_def in job_cols.items():
                if col not in existing_cols:
                    try:
                        conn.execute(f"ALTER TABLE jobs ADD COLUMN {col} {col_def}")
                    except Exception:
                        pass

            node_cols = {
                "is_drained": "INTEGER NOT NULL DEFAULT 0",
                "storage_used_bytes": "INTEGER NOT NULL DEFAULT 0",
            }
            existing_node_cols = {row[1] for row in conn.execute("PRAGMA table_info(nodes)").fetchall()}
            for col, col_def in node_cols.items():
                if col not in existing_node_cols:
                    try:
                        conn.execute(f"ALTER TABLE nodes ADD COLUMN {col} {col_def}")
                    except Exception:
                        pass

            gw_cols = {
                "wireguard_status": "TEXT NOT NULL DEFAULT 'READY'",
                "wireguard_status_detail": "TEXT NOT NULL DEFAULT ''",
                "userspace_fallback_ready": "INTEGER NOT NULL DEFAULT 1",
                "wireguard_private_key": "TEXT",
            }
            existing_gw_cols = {row[1] for row in conn.execute("PRAGMA table_info(cybernet_gateways)").fetchall()}
            for col, col_def in gw_cols.items():
                if col not in existing_gw_cols:
                    try:
                        conn.execute(f"ALTER TABLE cybernet_gateways ADD COLUMN {col} {col_def}")
                    except Exception:
                        pass
            conn.commit()

    # --- Setting Operations ---
    def get_setting(self, key: str, default: Optional[str] = None) -> Optional[str]:
        with self.connection() as conn:
            row = conn.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
            return row["value"] if row else default

    def set_setting(self, key: str, value: str):
        with self.connection() as conn:
            conn.execute(
                "INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
                (key, value, time.time()),
            )
            conn.commit()

    # --- Node Operations ---
    def upsert_node_enrollment(self, node_id: str, name: str, secret_hash: str, **kwargs):
        with self.connection() as conn:
            now = time.time()
            conn.execute(
                """
                INSERT INTO nodes (
                    id, name, secret_hash, hostname, os, arch, privilege_mode,
                    environment, status, enrolled_at, last_heartbeat, capabilities_json, region
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'ONLINE', ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name=excluded.name,
                    secret_hash=excluded.secret_hash,
                    status='ONLINE',
                    last_heartbeat=excluded.last_heartbeat
                """,
                (
                    node_id,
                    name,
                    secret_hash,
                    kwargs.get("hostname", "unknown"),
                    kwargs.get("os", "linux"),
                    kwargs.get("arch", "x86_64"),
                    kwargs.get("privilege_mode", "ROOTLESS"),
                    kwargs.get("environment", "vps"),
                    now,
                    now,
                    json.dumps(kwargs.get("capabilities", {})),
                    kwargs.get("region"),
                ),
            )
            conn.commit()

    def get_node(self, node_id: str) -> Optional[Dict[str, Any]]:
        with self.connection() as conn:
            row = conn.execute("SELECT * FROM nodes WHERE id = ?", (node_id,)).fetchone()
            if not row:
                return None
            data = dict(row)
            try:
                data["capabilities"] = json.loads(data.get("capabilities_json") or "{}")
            except Exception:
                data["capabilities"] = {}
            return data

    def get_node_by_name(self, name: str) -> Optional[Dict[str, Any]]:
        with self.connection() as conn:
            row = conn.execute("SELECT * FROM nodes WHERE name = ?", (name,)).fetchone()
            if not row:
                return None
            data = dict(row)
            try:
                data["capabilities"] = json.loads(data.get("capabilities_json") or "{}")
            except Exception:
                data["capabilities"] = {}
            return data

    def list_nodes(self) -> List[Dict[str, Any]]:
        with self.connection() as conn:
            rows = conn.execute("SELECT * FROM nodes ORDER BY enrolled_at ASC").fetchall()
            nodes = []
            for r in rows:
                d = dict(r)
                try:
                    d["capabilities"] = json.loads(d.get("capabilities_json") or "{}")
                except Exception:
                    d["capabilities"] = {}
                nodes.append(d)
            return nodes

    def update_node_heartbeat(self, node_id: str, data: Dict[str, Any]):
        with self.connection() as conn:
            now = time.time()
            conn.execute(
                """
                UPDATE nodes SET
                    last_heartbeat = ?,
                    status = 'ONLINE',
                    agent_version = ?,
                    hostname = ?,
                    os = ?,
                    arch = ?,
                    environment = ?,
                    privilege_mode = ?,
                    effective_cpu = ?,
                    visible_cpu = ?,
                    effective_ram_bytes = ?,
                    visible_ram_bytes = ?,
                    ram_used_bytes = ?,
                    disk_total_bytes = ?,
                    disk_free_bytes = ?,
                    live_rx_bps = ?,
                    live_tx_bps = ?,
                    active_jobs_count = ?,
                    capabilities_json = ?
                WHERE id = ?
                """,
                (
                    now,
                    data.get("agent_version", "2.0.0"),
                    data.get("hostname", "unknown"),
                    data.get("os", "linux"),
                    data.get("arch", "x86_64"),
                    data.get("environment", "vps"),
                    data.get("privilege_mode", "ROOTLESS"),
                    data.get("effective_cpu", 1.0),
                    data.get("visible_cpu", 1),
                    data.get("effective_ram_bytes", 0),
                    data.get("visible_ram_bytes", 0),
                    data.get("ram_used_bytes", 0),
                    data.get("disk_total_bytes", 0),
                    data.get("disk_free_bytes", 0),
                    data.get("live_rx_bps", 0.0),
                    data.get("live_tx_bps", 0.0),
                    data.get("active_jobs_count", 0),
                    json.dumps(data.get("capabilities", {})),
                    node_id,
                ),
            )
            conn.commit()

    def set_node_status(self, node_id: str, status: Any):
        val = status.value if hasattr(status, "value") else str(status)
        with self.connection() as conn:
            conn.execute("UPDATE nodes SET status = ? WHERE id = ?", (val, node_id))
            conn.commit()

    def update_node_benchmark(self, node_id: str, dl_bps: float, ul_bps: float):
        with self.connection() as conn:
            conn.execute(
                "UPDATE nodes SET last_benchmark_dl_bps = ?, last_benchmark_ul_bps = ?, benchmark_timestamp = ? WHERE id = ?",
                (dl_bps, ul_bps, time.time(), node_id),
            )
            conn.commit()

    def record_node_transfer_completion(self, node_id: str, bytes_transferred: int, avg_speed_bps: float, success: bool):
        with self.connection() as conn:
            row = conn.execute(
                "SELECT recent_avg_speed_bps, recent_peak_speed_bps, total_bytes_transferred, "
                "reliability_score, failure_count, success_count FROM nodes WHERE id = ?",
                (node_id,),
            ).fetchone()
            if not row:
                return
            
            cur_avg = row["recent_avg_speed_bps"]
            cur_peak = row["recent_peak_speed_bps"]
            cur_total = row["total_bytes_transferred"]
            s_count = row["success_count"]
            f_count = row["failure_count"]
            
            if success:
                s_count += 1
                new_avg = avg_speed_bps if cur_avg == 0 else (cur_avg * 0.7 + avg_speed_bps * 0.3)
                new_peak = max(cur_peak, avg_speed_bps)
                new_total = cur_total + bytes_transferred
            else:
                f_count += 1
                new_avg = cur_avg
                new_peak = cur_peak
                new_total = cur_total
            
            total_transfers = s_count + f_count
            reliability = (s_count / total_transfers * 100.0) if total_transfers > 0 else 100.0
            
            conn.execute(
                """
                UPDATE nodes SET
                    recent_avg_speed_bps = ?,
                    recent_peak_speed_bps = ?,
                    total_bytes_transferred = ?,
                    success_count = ?,
                    failure_count = ?,
                    reliability_score = ?
                WHERE id = ?
                """,
                (new_avg, new_peak, new_total, s_count, f_count, round(reliability, 1), node_id),
            )
            conn.commit()

    @staticmethod
    def _row_to_job(row) -> JobRecord:
        d = dict(row)
        if "worker_nodes_json" in d:
            try:
                d["worker_nodes"] = json.loads(d.pop("worker_nodes_json") or "[]")
            except Exception:
                d["worker_nodes"] = []
        elif "worker_nodes" not in d:
            d["worker_nodes"] = []
        return JobRecord(**d)

    # --- Job Operations ---
    def create_job(self, job: JobRecord):
        with self.connection() as conn:
            conn.execute(
                """
                INSERT INTO jobs (
                    id, requested_url, resolved_url, filename, content_type,
                    expected_size, downloaded_bytes, progress_percent, current_speed_bps,
                    peak_speed_bps, average_speed_bps, eta_seconds, status, mode, node_id,
                    assembler_node, chunks_total, chunks_completed, transfer_path,
                    fleet_speed_bps, worker_nodes_json, replicas,
                    selection_reason, sha256, local_path, created_at, started_at,
                    completed_at, retry_count, max_retries, failure_reason,
                    telegram_chat_id, telegram_message_id, telegram_delivered,
                    signed_link_token, signed_link_expires_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    job.id, job.requested_url, job.resolved_url, job.filename, job.content_type,
                    job.expected_size, job.downloaded_bytes, job.progress_percent, job.current_speed_bps,
                    job.peak_speed_bps, job.average_speed_bps, job.eta_seconds,
                    job.status.value if hasattr(job.status, "value") else str(job.status),
                    job.mode, job.node_id, job.assembler_node, job.chunks_total, job.chunks_completed,
                    job.transfer_path, job.fleet_speed_bps, json.dumps(job.worker_nodes), job.replicas,
                    job.selection_reason, job.sha256, job.local_path, job.created_at, job.started_at,
                    job.completed_at, job.retry_count, job.max_retries, job.failure_reason,
                    job.telegram_chat_id, job.telegram_message_id, 1 if job.telegram_delivered else 0,
                    job.signed_link_token, job.signed_link_expires_at
                ),
            )
            conn.commit()

    def get_job(self, job_id: str) -> Optional[JobRecord]:
        with self.connection() as conn:
            row = conn.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
            if not row:
                return None
            return self._row_to_job(row)

    def list_jobs(self, status: Optional[str] = None, limit: int = 50) -> List[JobRecord]:
        with self.connection() as conn:
            if status:
                rows = conn.execute(
                    "SELECT * FROM jobs WHERE status = ? ORDER BY created_at DESC LIMIT ?",
                    (status, limit),
                ).fetchall()
            else:
                rows = conn.execute(
                    "SELECT * FROM jobs ORDER BY created_at DESC LIMIT ?", (limit,)
                ).fetchall()
            return [self._row_to_job(r) for r in rows]

    def update_job_progress(self, job_id: str, downloaded_bytes: int, total_bytes: int, speed: float, eta: int):
        with self.connection() as conn:
            percent = (downloaded_bytes / total_bytes * 100.0) if total_bytes > 0 else 0.0
            row = conn.execute("SELECT peak_speed_bps, average_speed_bps FROM jobs WHERE id = ?", (job_id,)).fetchone()
            peak = max(row["peak_speed_bps"] if row else 0.0, speed)
            avg = speed if not row or row["average_speed_bps"] == 0 else (row["average_speed_bps"] * 0.8 + speed * 0.2)
            
            conn.execute(
                """
                UPDATE jobs SET
                    downloaded_bytes = ?,
                    expected_size = CASE WHEN expected_size = 0 AND ? > 0 THEN ? ELSE expected_size END,
                    progress_percent = ?,
                    current_speed_bps = ?,
                    peak_speed_bps = ?,
                    average_speed_bps = ?,
                    eta_seconds = ?
                WHERE id = ?
                """,
                (downloaded_bytes, total_bytes, total_bytes, round(percent, 1), speed, peak, avg, eta, job_id),
            )
            conn.commit()

    def update_job_status(self, job_id: str, status: Any, failure_reason: str = ""):
        val = status.value if hasattr(status, "value") else str(status)
        with self.connection() as conn:
            now = time.time()
            extra_set = ""
            params = [val, failure_reason]
            if val == JobStatus.DOWNLOADING.value or val == "DOWNLOADING":
                extra_set = ", started_at = CASE WHEN started_at = 0 THEN ? ELSE started_at END"
                params.append(now)
            elif val in (JobStatus.COMPLETED.value, JobStatus.FAILED.value, JobStatus.CANCELLED.value, "COMPLETED", "FAILED", "CANCELLED"):
                extra_set = ", completed_at = ?"
                params.append(now)
            params.append(job_id)

            conn.execute(
                f"UPDATE jobs SET status = ?, failure_reason = ? {extra_set} WHERE id = ?",
                params,
            )
            conn.commit()

    def complete_job(self, job_id: str, sha256: str, size: int, path: str):
        with self.connection() as conn:
            now = time.time()
            conn.execute(
                """
                UPDATE jobs SET
                    status = 'COMPLETED',
                    sha256 = ?,
                    downloaded_bytes = ?,
                    expected_size = CASE WHEN expected_size = 0 THEN ? ELSE expected_size END,
                    progress_percent = 100.0,
                    current_speed_bps = 0.0,
                    eta_seconds = 0,
                    local_path = ?,
                    completed_at = ?
                WHERE id = ?
                """,
                (sha256, size, size, path, now, job_id),
            )
            conn.commit()

    def update_job_telegram_delivery(self, job_id: str, delivered: bool):
        with self.connection() as conn:
            conn.execute(
                "UPDATE jobs SET telegram_delivered = ? WHERE id = ?",
                (1 if delivered else 0, job_id),
            )
            conn.commit()

    def update_job_signed_link(self, job_id: str, token: str, expires_at: float):
        with self.connection() as conn:
            conn.execute(
                "UPDATE jobs SET signed_link_token = ?, signed_link_expires_at = ? WHERE id = ?",
                (token, expires_at, job_id),
            )
            conn.commit()

    # --- Signed Link Operations ---
    def create_signed_link(self, token: str, job_id: str, file_path: str, filename: str, file_size: int, expires_at: float, max_downloads: int = 0):
        with self.connection() as conn:
            conn.execute(
                """
                INSERT INTO signed_links (
                    token, job_id, file_path, filename, file_size, created_at, expires_at, max_downloads, revoked
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
                """,
                (token, job_id, file_path, filename, file_size, time.time(), expires_at, max_downloads),
            )
            conn.commit()

    def get_signed_link(self, token: str) -> Optional[Dict[str, Any]]:
        with self.connection() as conn:
            row = conn.execute("SELECT * FROM signed_links WHERE token = ?", (token,)).fetchone()
            return dict(row) if row else None

    def record_signed_link_download(self, token: str):
        with self.connection() as conn:
            conn.execute(
                "UPDATE signed_links SET downloads_count = downloads_count + 1 WHERE token = ?",
                (token,),
            )
            conn.commit()

    def revoke_signed_link(self, token: str):
        with self.connection() as conn:
            conn.execute("UPDATE signed_links SET revoked = 1 WHERE token = ?", (token,))
            conn.commit()

    # --- Audit Log Operations ---
    def log_audit(self, actor: str, action: str, target: str, result: str, detail: str = ""):
        with self.connection() as conn:
            conn.execute(
                "INSERT INTO audit_log (timestamp, actor, action, target, result, detail) VALUES (?, ?, ?, ?, ?, ?)",
                (time.time(), actor, action, target, result, detail),
            )
            conn.commit()

    def get_audit_logs(self, limit: int = 100) -> List[Dict[str, Any]]:
        with self.connection() as conn:
            rows = conn.execute("SELECT * FROM audit_log ORDER BY timestamp DESC LIMIT ?", (limit,)).fetchall()
            return [dict(r) for r in rows]

    # --- Chunk Operations (Phase 2 BURST) ---
    def create_chunks(self, chunks: List[DownloadChunk]):
        with self.connection() as conn:
            for c in chunks:
                conn.execute(
                    """
                    INSERT INTO chunks (
                        chunk_id, job_id, chunk_index, start_byte, end_byte,
                        expected_length, downloaded_bytes, node_id, status,
                        attempt_count, checksum, speed_bps, created_at,
                        started_at, completed_at, local_path
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(chunk_id) DO UPDATE SET
                        status = excluded.status,
                        node_id = excluded.node_id
                    """,
                    (
                        c.chunk_id, c.job_id, c.chunk_index, c.start_byte, c.end_byte,
                        c.expected_length, c.downloaded_bytes, c.node_id,
                        c.status.value if hasattr(c.status, "value") else str(c.status),
                        c.attempt_count, c.checksum, c.speed_bps, c.created_at,
                        c.started_at, c.completed_at, c.local_path
                    )
                )
            conn.commit()

    def get_chunks_for_job(self, job_id: str) -> List[DownloadChunk]:
        with self.connection() as conn:
            rows = conn.execute(
                "SELECT * FROM chunks WHERE job_id = ? ORDER BY chunk_index ASC",
                (job_id,)
            ).fetchall()
            return [DownloadChunk(**dict(r)) for r in rows]

    def get_chunk(self, chunk_id: str) -> Optional[DownloadChunk]:
        with self.connection() as conn:
            row = conn.execute("SELECT * FROM chunks WHERE chunk_id = ?", (chunk_id,)).fetchone()
            return DownloadChunk(**dict(row)) if row else None

    def get_pending_chunks(self, job_id: str) -> List[DownloadChunk]:
        with self.connection() as conn:
            rows = conn.execute(
                "SELECT * FROM chunks WHERE job_id = ? AND status IN ('PENDING', 'REQUEUED') ORDER BY chunk_index ASC",
                (job_id,)
            ).fetchall()
            return [DownloadChunk(**dict(r)) for r in rows]

    def assign_chunk(self, chunk_id: str, node_id: str):
        with self.connection() as conn:
            now = time.time()
            conn.execute(
                """
                UPDATE chunks SET
                    status = 'ASSIGNED',
                    node_id = ?,
                    started_at = ?,
                    attempt_count = attempt_count + 1
                WHERE chunk_id = ?
                """,
                (node_id, now, chunk_id)
            )
            # Add node_id to job's worker_nodes if not already present
            chunk = conn.execute("SELECT job_id FROM chunks WHERE chunk_id = ?", (chunk_id,)).fetchone()
            if chunk:
                job_id = chunk["job_id"]
                jrow = conn.execute("SELECT worker_nodes_json FROM jobs WHERE id = ?", (job_id,)).fetchone()
                if jrow:
                    try:
                        workers = json.loads(jrow["worker_nodes_json"] or "[]")
                    except Exception:
                        workers = []
                    if node_id not in workers:
                        workers.append(node_id)
                        conn.execute("UPDATE jobs SET worker_nodes_json = ? WHERE id = ?", (json.dumps(workers), job_id))
            conn.commit()

    def update_chunk_progress(self, chunk_id: str, downloaded_bytes: int, speed_bps: float):
        with self.connection() as conn:
            conn.execute(
                """
                UPDATE chunks SET
                    downloaded_bytes = ?,
                    speed_bps = ?,
                    status = 'DOWNLOADING'
                WHERE chunk_id = ?
                """,
                (downloaded_bytes, speed_bps, chunk_id)
            )
            chunk = conn.execute("SELECT job_id FROM chunks WHERE chunk_id = ?", (chunk_id,)).fetchone()
            if chunk:
                self._recalculate_job_progress(conn, chunk["job_id"])
            conn.commit()

    def complete_chunk(self, chunk_id: str, checksum: str, local_path: str):
        with self.connection() as conn:
            now = time.time()
            conn.execute(
                """
                UPDATE chunks SET
                    status = 'COMPLETE',
                    checksum = ?,
                    local_path = ?,
                    completed_at = ?,
                    downloaded_bytes = expected_length,
                    speed_bps = 0.0
                WHERE chunk_id = ?
                """,
                (checksum, local_path, now, chunk_id)
            )
            chunk = conn.execute("SELECT job_id FROM chunks WHERE chunk_id = ?", (chunk_id,)).fetchone()
            if chunk:
                self._recalculate_job_progress(conn, chunk["job_id"])
            conn.commit()

    def fail_or_requeue_chunk(self, chunk_id: str, status: str = "REQUEUED", reason: str = ""):
        with self.connection() as conn:
            conn.execute(
                """
                UPDATE chunks SET
                    status = ?,
                    node_id = CASE WHEN ? = 'REQUEUED' THEN NULL ELSE node_id END,
                    speed_bps = 0.0
                WHERE chunk_id = ?
                """,
                (status, status, chunk_id)
            )
            chunk = conn.execute("SELECT job_id FROM chunks WHERE chunk_id = ?", (chunk_id,)).fetchone()
            if chunk:
                self._recalculate_job_progress(conn, chunk["job_id"])
            conn.commit()

    def reassign_node_chunks_on_loss(self, node_id: str) -> int:
        with self.connection() as conn:
            rows = conn.execute(
                """
                SELECT chunk_id, job_id FROM chunks
                WHERE node_id = ? AND status IN ('ASSIGNED', 'DOWNLOADING')
                """,
                (node_id,)
            ).fetchall()
            if not rows:
                return 0
            conn.execute(
                """
                UPDATE chunks SET
                    status = 'REQUEUED',
                    node_id = NULL,
                    speed_bps = 0.0
                WHERE node_id = ? AND status IN ('ASSIGNED', 'DOWNLOADING')
                """,
                (node_id,)
            )
            for r in rows:
                self._recalculate_job_progress(conn, r["job_id"])
            conn.commit()
            return len(rows)

    def _recalculate_job_progress(self, conn, job_id: str):
        stats = conn.execute(
            """
            SELECT
                COUNT(*) as total,
                SUM(CASE WHEN status IN ('COMPLETE', 'VERIFIED') THEN 1 ELSE 0 END) as completed,
                SUM(downloaded_bytes) as dl_bytes,
                SUM(expected_length) as exp_bytes,
                SUM(speed_bps) as total_speed
            FROM chunks WHERE job_id = ?
            """,
            (job_id,)
        ).fetchone()
        if stats and stats["total"] > 0:
            tot = stats["total"]
            comp = stats["completed"] or 0
            dl_bytes = stats["dl_bytes"] or 0
            exp_bytes = stats["exp_bytes"] or 0
            fleet_speed = stats["total_speed"] or 0.0
            percent = (dl_bytes / exp_bytes * 100.0) if exp_bytes > 0 else 0.0
            eta = int((exp_bytes - dl_bytes) / (fleet_speed / 8.0)) if fleet_speed > 0 and exp_bytes > dl_bytes else 0
            
            conn.execute(
                """
                UPDATE jobs SET
                    chunks_total = ?,
                    chunks_completed = ?,
                    downloaded_bytes = ?,
                    progress_percent = ?,
                    current_speed_bps = ?,
                    fleet_speed_bps = ?,
                    eta_seconds = ?
                WHERE id = ?
                """,
                (tot, comp, dl_bytes, round(percent, 1), fleet_speed, fleet_speed, eta, job_id)
            )

    # --- Transfer Tickets ---
    def create_transfer_ticket(self, ticket: TransferTicket):
        with self.connection() as conn:
            conn.execute(
                """
                INSERT INTO transfer_tickets (
                    ticket_id, job_id, chunk_id, source_node, destination_node,
                    expires_at, nonce, signature, used
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(ticket_id) DO NOTHING
                """,
                (
                    ticket.ticket_id, ticket.job_id, ticket.chunk_id, ticket.source_node,
                    ticket.destination_node, ticket.expires_at, ticket.nonce,
                    ticket.signature, 1 if ticket.used else 0
                )
            )
            conn.commit()

    def get_transfer_ticket(self, ticket_id: str) -> Optional[TransferTicket]:
        with self.connection() as conn:
            row = conn.execute("SELECT * FROM transfer_tickets WHERE ticket_id = ?", (ticket_id,)).fetchone()
            if not row:
                return None
            d = dict(row)
            d["used"] = bool(d["used"])
            return TransferTicket(**d)

    def mark_ticket_used(self, ticket_id: str):
        with self.connection() as conn:
            conn.execute("UPDATE transfer_tickets SET used = 1 WHERE ticket_id = ?", (ticket_id,))
            conn.commit()

    # --- CyberStore Operations ---
    def upsert_storage_object(self, object_hash: str, size_bytes: int, pinned: bool = False) -> StorageObject:
        with self.connection() as conn:
            now = time.time()
            conn.execute(
                """
                INSERT INTO storage_objects (object_hash, size_bytes, reference_count, created_at, last_accessed_at, pinned)
                VALUES (?, ?, 1, ?, ?, ?)
                ON CONFLICT(object_hash) DO UPDATE SET
                    last_accessed_at = excluded.last_accessed_at,
                    reference_count = reference_count + 1
                """,
                (object_hash, size_bytes, now, now, 1 if pinned else 0)
            )
            conn.commit()
            row = conn.execute("SELECT * FROM storage_objects WHERE object_hash = ?", (object_hash,)).fetchone()
            d = dict(row)
            d["pinned"] = bool(d["pinned"])
            return StorageObject(**d)

    def increment_object_ref(self, object_hash: str):
        with self.connection() as conn:
            conn.execute(
                "UPDATE storage_objects SET reference_count = reference_count + 1, last_accessed_at = ? WHERE object_hash = ?",
                (time.time(), object_hash)
            )
            conn.commit()

    def decrement_object_ref(self, object_hash: str) -> int:
        with self.connection() as conn:
            conn.execute(
                "UPDATE storage_objects SET reference_count = MAX(0, reference_count - 1), last_accessed_at = ? WHERE object_hash = ?",
                (time.time(), object_hash)
            )
            conn.commit()
            row = conn.execute("SELECT reference_count FROM storage_objects WHERE object_hash = ?", (object_hash,)).fetchone()
            return row["reference_count"] if row else 0

    def add_storage_replica(self, object_hash: str, node_id: str, local_rel_path: str, size_bytes: int):
        with self.connection() as conn:
            now = time.time()
            conn.execute(
                """
                INSERT INTO storage_replicas (object_hash, node_id, local_rel_path, size_bytes, is_healthy, stored_at)
                VALUES (?, ?, ?, ?, 1, ?)
                ON CONFLICT(object_hash, node_id) DO UPDATE SET
                    local_rel_path = excluded.local_rel_path,
                    is_healthy = 1,
                    stored_at = excluded.stored_at
                """,
                (object_hash, node_id, local_rel_path, size_bytes, now)
            )
            conn.execute(
                "UPDATE nodes SET storage_used_bytes = (SELECT COALESCE(SUM(size_bytes), 0) FROM storage_replicas WHERE node_id = ?) WHERE id = ?",
                (node_id, node_id)
            )
            conn.commit()

    def get_storage_replicas(self, object_hash: str) -> List[Dict[str, Any]]:
        with self.connection() as conn:
            rows = conn.execute("SELECT * FROM storage_replicas WHERE object_hash = ?", (object_hash,)).fetchall()
            return [dict(r) for r in rows]

    def remove_storage_replica(self, object_hash: str, node_id: str):
        with self.connection() as conn:
            conn.execute("DELETE FROM storage_replicas WHERE object_hash = ? AND node_id = ?", (object_hash, node_id))
            conn.execute(
                "UPDATE nodes SET storage_used_bytes = (SELECT COALESCE(SUM(size_bytes), 0) FROM storage_replicas WHERE node_id = ?) WHERE id = ?",
                (node_id, node_id)
            )
            conn.commit()

    def create_stored_file(self, file_id: str, filename: str, size_bytes: int, final_hash: str, replication_factor: int, chunks: List[Dict[str, Any]]):
        with self.connection() as conn:
            now = time.time()
            conn.execute(
                """
                INSERT INTO stored_files (file_id, filename, size_bytes, final_hash, replication_factor, created_at, status)
                VALUES (?, ?, ?, ?, ?, ?, 'HEALTHY')
                ON CONFLICT(file_id) DO UPDATE SET
                    filename = excluded.filename,
                    size_bytes = excluded.size_bytes,
                    final_hash = excluded.final_hash
                """,
                (file_id, filename, size_bytes, final_hash, replication_factor, now)
            )
            for c in chunks:
                conn.execute(
                    """
                    INSERT INTO stored_file_chunks (file_id, chunk_index, object_hash, start_byte, end_byte)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(file_id, chunk_index) DO UPDATE SET
                        object_hash = excluded.object_hash,
                        start_byte = excluded.start_byte,
                        end_byte = excluded.end_byte
                    """,
                    (file_id, c["chunk_index"], c["object_hash"], c["start_byte"], c["end_byte"])
                )
            conn.commit()

    def get_stored_file(self, file_id: str) -> Optional[Dict[str, Any]]:
        with self.connection() as conn:
            row = conn.execute("SELECT * FROM stored_files WHERE file_id = ?", (file_id,)).fetchone()
            if not row:
                return None
            f = dict(row)
            c_rows = conn.execute(
                "SELECT * FROM stored_file_chunks WHERE file_id = ? ORDER BY chunk_index ASC",
                (file_id,)
            ).fetchall()
            f["chunks"] = [dict(c) for c in c_rows]
            return f

    def list_stored_files(self) -> List[Dict[str, Any]]:
        with self.connection() as conn:
            rows = conn.execute("SELECT * FROM stored_files ORDER BY created_at DESC").fetchall()
            return [dict(r) for r in rows]

    def get_under_replicated_files(self) -> List[Dict[str, Any]]:
        with self.connection() as conn:
            files = self.list_stored_files()
            under = []
            for f in files:
                desired = f.get("replication_factor", 2)
                c_rows = conn.execute("SELECT object_hash FROM stored_file_chunks WHERE file_id = ?", (f["file_id"],)).fetchall()
                min_reps = desired
                for cr in c_rows:
                    rep_count = conn.execute("SELECT COUNT(*) as c FROM storage_replicas WHERE object_hash = ? AND is_healthy = 1", (cr["object_hash"],)).fetchone()["c"]
                    if rep_count < min_reps:
                        min_reps = rep_count
                if min_reps < desired:
                    f["current_replicas"] = min_reps
                    under.append(f)
            return under

    def get_cyberstore_summary(self) -> Dict[str, Any]:
        with self.connection() as conn:
            obj_stats = conn.execute(
                "SELECT COUNT(*) as count, COALESCE(SUM(size_bytes), 0) as physical_bytes, COALESCE(SUM(size_bytes * reference_count), 0) as logical_bytes FROM storage_objects"
            ).fetchone()
            rep_stats = conn.execute("SELECT COUNT(*) as count FROM storage_replicas WHERE is_healthy = 1").fetchone()
            file_count = conn.execute("SELECT COUNT(*) as count FROM stored_files").fetchone()["count"]
            node_count = conn.execute("SELECT COUNT(*) as count FROM nodes WHERE status != 'REVOKED'").fetchone()["count"]
            
            phys = obj_stats["physical_bytes"] if obj_stats else 0
            logi = obj_stats["logical_bytes"] if obj_stats else 0
            dedup_saved = max(0, logi - phys)
            
            under_rep = len(self.get_under_replicated_files())
            total_chunks = obj_stats["count"] if obj_stats else 0
            healthy_pct = 100.0 if under_rep == 0 else round(max(0.0, 100.0 - (under_rep * 10.0)), 1)
            
            dedup_savings_pct = (dedup_saved / logi * 100.0) if logi > 0 else 0.0
            return {
                "total_files": file_count,
                "total_stored_files": file_count,
                "total_objects": total_chunks,
                "total_unique_objects": total_chunks,
                "total_replicas": rep_stats["count"] if rep_stats else 0,
                "physical_bytes": phys,
                "total_physical_bytes": phys,
                "logical_bytes": logi,
                "total_logical_bytes": logi,
                "dedup_saved_bytes": dedup_saved,
                "dedup_savings_percent": dedup_savings_pct,
                "under_replicated_files": under_rep,
                "healthy_chunks_percent": healthy_pct,
                "storage_nodes_count": node_count,
            }

    def garbage_collect_objects(self, dry_run: bool = True) -> Dict[str, Any]:
        with self.connection() as conn:
            candidates = conn.execute(
                "SELECT object_hash, size_bytes FROM storage_objects WHERE reference_count <= 0 AND pinned = 0"
            ).fetchall()
            hashes = [c["object_hash"] for c in candidates]
            freed_bytes = sum(c["size_bytes"] for c in candidates)
            
            if not dry_run and hashes:
                placeholders = ",".join("?" * len(hashes))
                conn.execute(f"DELETE FROM storage_replicas WHERE object_hash IN ({placeholders})", hashes)
                conn.execute(f"DELETE FROM storage_objects WHERE object_hash IN ({placeholders})", hashes)
                conn.commit()
            
            return {
                "dry_run": dry_run,
                "candidate_count": len(hashes),
                "reclaimable_bytes": freed_bytes,
                "hashes": hashes[:50]
            }

    # --- Node Drain & Safe Removal ---
    def drain_node(self, node_id: str, drained: bool = True):
        with self.connection() as conn:
            conn.execute("UPDATE nodes SET is_drained = ? WHERE id = ?", (1 if drained else 0, node_id))
            conn.commit()

    def is_node_drained(self, node_id: str) -> bool:
        with self.connection() as conn:
            row = conn.execute("SELECT is_drained FROM nodes WHERE id = ?", (node_id,)).fetchone()
            return bool(row["is_drained"]) if row else False

    def remove_node_safely(self, node_id: str, force: bool = False) -> Tuple[bool, str]:
        with self.connection() as conn:
            active = conn.execute("SELECT COUNT(*) as c FROM jobs WHERE node_id = ? AND status IN ('ASSIGNED', 'DOWNLOADING')", (node_id,)).fetchone()["c"]
            active_chunks = conn.execute("SELECT COUNT(*) as c FROM chunks WHERE node_id = ? AND status IN ('ASSIGNED', 'DOWNLOADING')", (node_id,)).fetchone()["c"]
            rep_rows = conn.execute("SELECT object_hash FROM storage_replicas WHERE node_id = ?", (node_id,)).fetchall()
            unique_objects = 0
            for r in rep_rows:
                h = r["object_hash"]
                count = conn.execute("SELECT COUNT(*) as c FROM storage_replicas WHERE object_hash = ?", (h,)).fetchone()["c"]
                if count <= 1:
                    unique_objects += 1
            
            if not force and (active > 0 or active_chunks > 0 or unique_objects > 0):
                return False, f"Active transfers ({active} jobs, {active_chunks} chunks) or {unique_objects} unique replicas reside on this node."
            
            conn.execute("DELETE FROM storage_replicas WHERE node_id = ?", (node_id,))
            conn.execute("UPDATE nodes SET status = 'REVOKED', is_drained = 1 WHERE id = ?", (node_id,))
            conn.commit()
            return True, f"Node {node_id} removed safely ({len(rep_rows)} replicas cleaned up)."

    # =================================================================
    # Phase 3: CyberNet Operations
    # =================================================================

    def enroll_device(
        self,
        device_id: str,
        name: str,
        device_type: str,
        os_version: str,
        public_key: str,
        auth_token_hash: str,
    ) -> CyberNetDevice:
        now = time.time()
        with self.connection() as conn:
            conn.execute(
                """
                INSERT INTO cybernet_devices (id, name, device_type, os_version, public_key, status, enrolled_at, last_seen_at, auth_token_hash)
                VALUES (?, ?, ?, ?, ?, 'ACTIVE', ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    device_type = excluded.device_type,
                    os_version = excluded.os_version,
                    public_key = excluded.public_key,
                    status = 'ACTIVE',
                    last_seen_at = excluded.last_seen_at,
                    auth_token_hash = excluded.auth_token_hash
                """,
                (device_id, name, device_type, os_version, public_key, now, now, auth_token_hash),
            )
            conn.commit()
        return self.get_device(device_id)

    def get_device(self, device_id: str) -> Optional[CyberNetDevice]:
        with self.connection() as conn:
            row = conn.execute("SELECT * FROM cybernet_devices WHERE id = ?", (device_id,)).fetchone()
            if not row:
                return None
            return CyberNetDevice(
                id=row["id"],
                name=row["name"],
                device_type=row["device_type"],
                os_version=row["os_version"],
                public_key=row["public_key"],
                status=CyberNetDeviceStatus(row["status"]),
                enrolled_at=row["enrolled_at"],
                last_seen_at=row["last_seen_at"],
                auth_token_hash=row["auth_token_hash"],
            )

    def get_device_by_token_hash(self, token_hash: str) -> Optional[CyberNetDevice]:
        with self.connection() as conn:
            row = conn.execute("SELECT * FROM cybernet_devices WHERE auth_token_hash = ?", (token_hash,)).fetchone()
            if not row:
                return None
            return CyberNetDevice(
                id=row["id"],
                name=row["name"],
                device_type=row["device_type"],
                os_version=row["os_version"],
                public_key=row["public_key"],
                status=CyberNetDeviceStatus(row["status"]),
                enrolled_at=row["enrolled_at"],
                last_seen_at=row["last_seen_at"],
                auth_token_hash=row["auth_token_hash"],
            )

    def list_devices(self) -> List[CyberNetDevice]:
        with self.connection() as conn:
            rows = conn.execute("SELECT * FROM cybernet_devices ORDER BY enrolled_at DESC").fetchall()
            return [
                CyberNetDevice(
                    id=r["id"],
                    name=r["name"],
                    device_type=r["device_type"],
                    os_version=r["os_version"],
                    public_key=r["public_key"],
                    status=CyberNetDeviceStatus(r["status"]),
                    enrolled_at=r["enrolled_at"],
                    last_seen_at=r["last_seen_at"],
                    auth_token_hash=r["auth_token_hash"],
                )
                for r in rows
            ]

    def revoke_device(self, device_id: str) -> bool:
        with self.connection() as conn:
            cur = conn.execute("UPDATE cybernet_devices SET status = 'REVOKED' WHERE id = ?", (device_id,))
            conn.execute(
                "UPDATE cybernet_sessions SET status = 'TERMINATED', end_time = ?, disconnect_reason = 'DEVICE_REVOKED' WHERE device_id = ? AND status = 'ACTIVE'",
                (time.time(), device_id),
            )
            conn.commit()
            return cur.rowcount > 0

    def update_device_last_seen(self, device_id: str):
        with self.connection() as conn:
            conn.execute("UPDATE cybernet_devices SET last_seen_at = ? WHERE id = ?", (time.time(), device_id))
            conn.commit()

    def create_enroll_token(self, ttl_seconds: int = 3600, created_by: str = "admin") -> str:
        token = f"net_{secrets.token_urlsafe(24)}"
        now = time.time()
        expires = now + ttl_seconds
        with self.connection() as conn:
            conn.execute(
                "INSERT INTO cybernet_enroll_tokens (token, created_at, expires_at, used, created_by) VALUES (?, ?, ?, 0, ?)",
                (token, now, expires, created_by),
            )
            conn.commit()
        return token

    def validate_and_consume_enroll_token(self, token: str) -> bool:
        now = time.time()
        with self.connection() as conn:
            row = conn.execute(
                "SELECT token, expires_at, used FROM cybernet_enroll_tokens WHERE token = ?",
                (token,),
            ).fetchone()
            if not row:
                return False
            if row["used"] == 1 or row["expires_at"] < now:
                return False
            conn.execute("UPDATE cybernet_enroll_tokens SET used = 1 WHERE token = ?", (token,))
            conn.commit()
            return True

    def list_enroll_tokens(self) -> List[Dict[str, Any]]:
        with self.connection() as conn:
            rows = conn.execute(
                "SELECT token, created_at, expires_at, used, created_by FROM cybernet_enroll_tokens ORDER BY created_at DESC"
            ).fetchall()
            return [dict(r) for r in rows]

    def set_gateway(
        self,
        node_id: str,
        enabled: bool = True,
        wireguard_enabled: bool = True,
        wireguard_port: int = 51820,
        wireguard_public_key: str = "",
        wireguard_subnet: str = "10.66.0.0/24",
        wireguard_status: str = "READY",
        wireguard_status_detail: str = "",
        userspace_fallback_ready: bool = True,
        wireguard_private_key: Optional[str] = None,
        ssh_enabled: bool = True,
        ssh_port: int = 22,
        udp_supported: bool = True,
        ipv4_address: str = "",
        ipv6_address: Optional[str] = None,
        region: str = "NL",
        latency_ms: float = 0.0,
        packet_loss: float = 0.0,
    ) -> CyberNetGatewayInfo:
        with self.connection() as conn:
            conn.execute(
                """
                INSERT INTO cybernet_gateways (
                    node_id, enabled, wireguard_enabled, wireguard_port, wireguard_public_key,
                    wireguard_subnet, wireguard_status, wireguard_status_detail, userspace_fallback_ready,
                    wireguard_private_key, ssh_enabled, ssh_port, udp_supported, ipv4_address,
                    ipv6_address, region, latency_ms, packet_loss
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(node_id) DO UPDATE SET
                    enabled = excluded.enabled,
                    wireguard_enabled = excluded.wireguard_enabled,
                    wireguard_port = excluded.wireguard_port,
                    wireguard_public_key = CASE WHEN excluded.wireguard_public_key != '' THEN excluded.wireguard_public_key ELSE cybernet_gateways.wireguard_public_key END,
                    wireguard_subnet = excluded.wireguard_subnet,
                    wireguard_status = excluded.wireguard_status,
                    wireguard_status_detail = excluded.wireguard_status_detail,
                    userspace_fallback_ready = excluded.userspace_fallback_ready,
                    wireguard_private_key = CASE WHEN excluded.wireguard_private_key IS NOT NULL THEN excluded.wireguard_private_key ELSE cybernet_gateways.wireguard_private_key END,
                    ssh_enabled = excluded.ssh_enabled,
                    ssh_port = excluded.ssh_port,
                    udp_supported = excluded.udp_supported,
                    ipv4_address = CASE WHEN excluded.ipv4_address != '' THEN excluded.ipv4_address ELSE cybernet_gateways.ipv4_address END,
                    ipv6_address = excluded.ipv6_address,
                    region = excluded.region,
                    latency_ms = CASE WHEN excluded.latency_ms > 0 THEN excluded.latency_ms ELSE cybernet_gateways.latency_ms END,
                    packet_loss = CASE WHEN excluded.packet_loss > 0 THEN excluded.packet_loss ELSE cybernet_gateways.packet_loss END
                """,
                (
                    node_id, 1 if enabled else 0, 1 if wireguard_enabled else 0,
                    wireguard_port, wireguard_public_key, wireguard_subnet,
                    wireguard_status, wireguard_status_detail, 1 if userspace_fallback_ready else 0,
                    wireguard_private_key,
                    1 if ssh_enabled else 0, ssh_port, 1 if udp_supported else 0,
                    ipv4_address, ipv6_address, region, latency_ms, packet_loss,
                ),
            )
            conn.commit()
        return self.get_gateway(node_id)

    def get_gateway(self, node_id: str) -> Optional[CyberNetGatewayInfo]:
        with self.connection() as conn:
            row = conn.execute("SELECT * FROM cybernet_gateways WHERE node_id = ?", (node_id,)).fetchone()
            if not row:
                return None
            keys = row.keys()
            return CyberNetGatewayInfo(
                node_id=row["node_id"],
                enabled=bool(row["enabled"]),
                wireguard_enabled=bool(row["wireguard_enabled"]),
                wireguard_port=row["wireguard_port"],
                wireguard_public_key=row["wireguard_public_key"],
                wireguard_subnet=row["wireguard_subnet"],
                wireguard_status=row["wireguard_status"] if "wireguard_status" in keys else "READY",
                wireguard_status_detail=row["wireguard_status_detail"] if "wireguard_status_detail" in keys else "",
                userspace_fallback_ready=bool(row["userspace_fallback_ready"]) if "userspace_fallback_ready" in keys else True,
                wireguard_private_key=row["wireguard_private_key"] if "wireguard_private_key" in keys else None,
                ssh_enabled=bool(row["ssh_enabled"]),
                ssh_port=row["ssh_port"],
                udp_supported=bool(row["udp_supported"]),
                ipv4_address=row["ipv4_address"],
                ipv6_address=row["ipv6_address"],
                region=row["region"],
                latency_ms=row["latency_ms"],
                packet_loss=row["packet_loss"],
                active_sessions=row["active_sessions"],
                tunnel_rx_bytes=row["tunnel_rx_bytes"],
                tunnel_tx_bytes=row["tunnel_tx_bytes"],
                gateway_score=row["gateway_score"],
            )

    def list_gateways(self, only_enabled: bool = True) -> List[CyberNetGatewayInfo]:
        with self.connection() as conn:
            sql = "SELECT * FROM cybernet_gateways"
            if only_enabled:
                sql += " WHERE enabled = 1"
            sql += " ORDER BY gateway_score DESC"
            rows = conn.execute(sql).fetchall()
            return [
                CyberNetGatewayInfo(
                    node_id=r["node_id"],
                    enabled=bool(r["enabled"]),
                    wireguard_enabled=bool(r["wireguard_enabled"]),
                    wireguard_port=r["wireguard_port"],
                    wireguard_public_key=r["wireguard_public_key"],
                    wireguard_subnet=r["wireguard_subnet"],
                    wireguard_status=r["wireguard_status"] if "wireguard_status" in r.keys() else "READY",
                    wireguard_status_detail=r["wireguard_status_detail"] if "wireguard_status_detail" in r.keys() else "",
                    userspace_fallback_ready=bool(r["userspace_fallback_ready"]) if "userspace_fallback_ready" in r.keys() else True,
                    wireguard_private_key=r["wireguard_private_key"] if "wireguard_private_key" in r.keys() else None,
                    ssh_enabled=bool(r["ssh_enabled"]),
                    ssh_port=r["ssh_port"],
                    udp_supported=bool(r["udp_supported"]),
                    ipv4_address=r["ipv4_address"],
                    ipv6_address=r["ipv6_address"],
                    region=r["region"],
                    latency_ms=r["latency_ms"],
                    packet_loss=r["packet_loss"],
                    active_sessions=r["active_sessions"],
                    tunnel_rx_bytes=r["tunnel_rx_bytes"],
                    tunnel_tx_bytes=r["tunnel_tx_bytes"],
                    gateway_score=r["gateway_score"],
                )
                for r in rows
            ]

    def update_gateway_telemetry(
        self,
        node_id: str,
        latency_ms: float = 0.0,
        packet_loss: float = 0.0,
        active_sessions: int = 0,
        tunnel_rx_bytes: int = 0,
        tunnel_tx_bytes: int = 0,
        gateway_score: float = 0.0,
    ):
        with self.connection() as conn:
            conn.execute(
                """
                UPDATE cybernet_gateways SET
                    latency_ms = ?,
                    packet_loss = ?,
                    active_sessions = ?,
                    tunnel_rx_bytes = tunnel_rx_bytes + ?,
                    tunnel_tx_bytes = tunnel_tx_bytes + ?,
                    gateway_score = ?
                WHERE node_id = ?
                """,
                (latency_ms, packet_loss, active_sessions, tunnel_rx_bytes, tunnel_tx_bytes, gateway_score, node_id),
            )
            conn.commit()

    def create_session(
        self,
        session_id: str,
        device_id: str,
        gateway_node_id: str,
        protocol: str = "WIREGUARD",
        assigned_ip: str = "10.66.0.2",
    ) -> CyberNetSessionRecord:
        now = time.time()
        with self.connection() as conn:
            conn.execute(
                "UPDATE cybernet_sessions SET status = 'TERMINATED', end_time = ?, disconnect_reason = 'NEW_SESSION' WHERE device_id = ? AND status = 'ACTIVE'",
                (now, device_id),
            )
            conn.execute(
                """
                INSERT INTO cybernet_sessions (session_id, device_id, gateway_node_id, protocol, assigned_ip, start_time, status)
                VALUES (?, ?, ?, ?, ?, ?, 'ACTIVE')
                """,
                (session_id, device_id, gateway_node_id, protocol, assigned_ip, now),
            )
            conn.execute(
                "UPDATE cybernet_gateways SET active_sessions = active_sessions + 1 WHERE node_id = ?",
                (gateway_node_id,),
            )
            conn.commit()
        return self.get_session(session_id)

    def get_session(self, session_id: str) -> Optional[CyberNetSessionRecord]:
        with self.connection() as conn:
            row = conn.execute("SELECT * FROM cybernet_sessions WHERE session_id = ?", (session_id,)).fetchone()
            if not row:
                return None
            return CyberNetSessionRecord(
                session_id=row["session_id"],
                device_id=row["device_id"],
                gateway_node_id=row["gateway_node_id"],
                protocol=CyberNetProtocol(row["protocol"]),
                assigned_ip=row["assigned_ip"],
                start_time=row["start_time"],
                end_time=row["end_time"],
                status=CyberNetSessionStatus(row["status"]),
                bytes_rx=row["bytes_rx"],
                bytes_tx=row["bytes_tx"],
                disconnect_reason=row["disconnect_reason"],
            )

    def get_active_session_for_device(self, device_id: str) -> Optional[CyberNetSessionRecord]:
        with self.connection() as conn:
            row = conn.execute("SELECT * FROM cybernet_sessions WHERE device_id = ? AND status = 'ACTIVE'", (device_id,)).fetchone()
            if not row:
                return None
            return CyberNetSessionRecord(
                session_id=row["session_id"],
                device_id=row["device_id"],
                gateway_node_id=row["gateway_node_id"],
                protocol=CyberNetProtocol(row["protocol"]),
                assigned_ip=row["assigned_ip"],
                start_time=row["start_time"],
                end_time=row["end_time"],
                status=CyberNetSessionStatus(row["status"]),
                bytes_rx=row["bytes_rx"],
                bytes_tx=row["bytes_tx"],
                disconnect_reason=row["disconnect_reason"],
            )

    def update_session_stats(self, session_id: str, bytes_rx: int, bytes_tx: int):
        with self.connection() as conn:
            conn.execute(
                "UPDATE cybernet_sessions SET bytes_rx = ?, bytes_tx = ? WHERE session_id = ?",
                (bytes_rx, bytes_tx, session_id),
            )
            conn.commit()

    def terminate_session(self, session_id: str, disconnect_reason: str = "USER_DISCONNECT") -> bool:
        now = time.time()
        with self.connection() as conn:
            sess = conn.execute("SELECT gateway_node_id, status FROM cybernet_sessions WHERE session_id = ?", (session_id,)).fetchone()
            if not sess or sess["status"] != "ACTIVE":
                return False
            conn.execute(
                "UPDATE cybernet_sessions SET status = 'TERMINATED', end_time = ?, disconnect_reason = ? WHERE session_id = ?",
                (now, disconnect_reason, session_id),
            )
            conn.execute(
                "UPDATE cybernet_gateways SET active_sessions = MAX(0, active_sessions - 1) WHERE node_id = ?",
                (sess["gateway_node_id"],),
            )
            conn.commit()
            return True

    def list_sessions(self, limit: int = 50) -> List[CyberNetSessionRecord]:
        with self.connection() as conn:
            rows = conn.execute("SELECT * FROM cybernet_sessions ORDER BY start_time DESC LIMIT ?", (limit,)).fetchall()
            return [
                CyberNetSessionRecord(
                    session_id=r["session_id"],
                    device_id=r["device_id"],
                    gateway_node_id=r["gateway_node_id"],
                    protocol=CyberNetProtocol(r["protocol"]),
                    assigned_ip=r["assigned_ip"],
                    start_time=r["start_time"],
                    end_time=r["end_time"],
                    status=CyberNetSessionStatus(r["status"]),
                    bytes_rx=r["bytes_rx"],
                    bytes_tx=r["bytes_tx"],
                    disconnect_reason=r["disconnect_reason"],
                )
                for r in rows
            ]

    def get_cybernet_summary(self) -> Dict[str, Any]:
        with self.connection() as conn:
            total_devs = conn.execute("SELECT COUNT(*) as c FROM cybernet_devices WHERE status = 'ACTIVE'").fetchone()["c"]
            online_devs = conn.execute("SELECT COUNT(DISTINCT device_id) as c FROM cybernet_sessions WHERE status = 'ACTIVE'").fetchone()["c"]
            total_gws = conn.execute("SELECT COUNT(*) as c FROM cybernet_gateways WHERE enabled = 1").fetchone()["c"]
            healthy_gws = conn.execute(
                """
                SELECT COUNT(*) as c FROM cybernet_gateways g
                JOIN nodes n ON g.node_id = n.id
                WHERE g.enabled = 1 AND n.status = 'ONLINE'
                """
            ).fetchone()["c"]
            total_sessions = conn.execute("SELECT COUNT(*) as c FROM cybernet_sessions").fetchone()["c"]
            active_sessions = conn.execute("SELECT COUNT(*) as c FROM cybernet_sessions WHERE status = 'ACTIVE'").fetchone()["c"]
            
            traffic = conn.execute(
                "SELECT SUM(tunnel_rx_bytes) as rx, SUM(tunnel_tx_bytes) as tx FROM cybernet_gateways"
            ).fetchone()
            vpn_rx = traffic["rx"] or 0
            vpn_tx = traffic["tx"] or 0

            return {
                "devices_total": total_devs,
                "devices_connected": online_devs,
                "gateways_total": total_gws,
                "gateways_healthy": healthy_gws,
                "sessions_total": total_sessions,
                "sessions_active": active_sessions,
                "fleet_vpn_rx_bytes": vpn_rx,
                "fleet_vpn_tx_bytes": vpn_tx,
            }

