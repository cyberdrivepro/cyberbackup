"""
SQLite database persistence engine for CyberFleet Controller.
Thread-safe, WAL enabled, 0600 permissions, auto-migrating schema.
"""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import sqlite3
import time
from typing import Any, Dict, List, Optional
from fleet.models import JobRecord, JobStatus, NodeRecord, NodeStatus


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

            CREATE INDEX IF NOT EXISTS idx_nodes_status ON nodes(status);
            CREATE INDEX IF NOT EXISTS idx_jobs_status ON jobs(status);
            CREATE INDEX IF NOT EXISTS idx_jobs_created_at ON jobs(created_at);
            CREATE INDEX IF NOT EXISTS idx_signed_links_expires ON signed_links(expires_at);
            """)

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

    # --- Job Operations ---
    def create_job(self, job: JobRecord):
        with self.connection() as conn:
            conn.execute(
                """
                INSERT INTO jobs (
                    id, requested_url, resolved_url, filename, content_type,
                    expected_size, downloaded_bytes, progress_percent, current_speed_bps,
                    peak_speed_bps, average_speed_bps, eta_seconds, status, node_id,
                    selection_reason, sha256, local_path, created_at, started_at,
                    completed_at, retry_count, max_retries, failure_reason,
                    telegram_chat_id, telegram_message_id, telegram_delivered,
                    signed_link_token, signed_link_expires_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    job.id, job.requested_url, job.resolved_url, job.filename, job.content_type,
                    job.expected_size, job.downloaded_bytes, job.progress_percent, job.current_speed_bps,
                    job.peak_speed_bps, job.average_speed_bps, job.eta_seconds, job.status.value, job.node_id,
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
            return JobRecord(**dict(row))

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
            return [JobRecord(**dict(r)) for r in rows]

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
