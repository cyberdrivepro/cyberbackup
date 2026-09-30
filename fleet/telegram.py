"""
Telegram Bot Integration Engine for CyberTransfer.
Supports command administration, bare URL submission, progressive message editing,
and dual-mode completion delivery (direct document upload or signed Cybershare link).
"""
import io
import json
import os
from pathlib import Path
import re
import threading
import time
from typing import Any, Callable, Dict, List, Optional
import urllib.error
import urllib.parse
import urllib.request


def get_telegram_config() -> Tuple[str, List[int]]:
    """Reads bot token and admin user IDs from 0600 config or environment."""
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    if not token:
        token_path = Path.home() / ".config" / "cybervps" / "telegram" / "bot_token"
        if token_path.is_file():
            try:
                token = token_path.read_text().strip()
            except Exception:
                token = ""

    admin_ids = []
    env_admins = os.environ.get("TELEGRAM_ADMIN_IDS", "").strip()
    if env_admins:
        for x in env_admins.replace(",", " ").split():
            if x.isdigit():
                admin_ids.append(int(x))

    if not admin_ids:
        cfg_path = Path.home() / ".config" / "cybervps" / "telegram" / "config.json"
        if cfg_path.is_file():
            try:
                data = json.loads(cfg_path.read_text())
                admin_ids = [int(u) for u in data.get("admin_user_ids", [])]
            except Exception:
                pass

    return token, admin_ids


def call_telegram_api(token: str, method: str, params: Optional[Dict[str, Any]] = None, timeout: float = 25.0) -> Dict[str, Any]:
    """Executes a request to Telegram Bot API."""
    if not token:
        return {"ok": False, "description": "Token not provided"}

    url = f"https://api.telegram.org/bot{token}/{method}"
    data = None
    headers = {"User-Agent": "CyberVPS-Bot/2.0"}

    if params:
        data = json.dumps(params).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode("utf-8"))
        except Exception:
            return {"ok": False, "description": f"HTTP {e.code}: {e.reason}"}
    except Exception as e:
        return {"ok": False, "description": str(e)}


def upload_telegram_document(token: str, chat_id: int, file_path: Path, caption: str = "") -> Dict[str, Any]:
    """Uploads a local file as document using multipart/form-data."""
    if not file_path.is_file():
        return {"ok": False, "description": "File not found"}

    boundary = f"----WebKitFormBoundary{os.urandom(8).hex()}"
    filename = file_path.name
    url = f"https://api.telegram.org/bot{token}/sendDocument"

    body = io.BytesIO()
    # chat_id
    body.write(f"--{boundary}\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n{chat_id}\r\n".encode("utf-8"))
    # caption
    if caption:
        body.write(f"--{boundary}\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\n{caption}\r\n".encode("utf-8"))
    # document
    body.write(f"--{boundary}\r\nContent-Disposition: form-data; name=\"document\"; filename=\"{filename}\"\r\nContent-Type: application/octet-stream\r\n\r\n".encode("utf-8"))

    with open(file_path, "rb") as f:
        while True:
            chunk = f.read(65536)
            if not chunk:
                break
            body.write(chunk)
    body.write(f"\r\n--{boundary}--\r\n".encode("utf-8"))

    data = body.getvalue()
    headers = {
        "Content-Type": f"multipart/form-data; boundary={boundary}",
        "Content-Length": str(len(data)),
        "User-Agent": "CyberVPS-Bot/2.0",
    }

    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=120.0) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        return {"ok": False, "description": str(e)}


class TelegramTransferBot:
    """Background polling bot daemon for CyberTransfer remote control."""
    def __init__(self, controller_api):
        self.controller = controller_api
        self.token, self.admin_ids = get_telegram_config()
        self.running = False
        self.poll_thread: Optional[threading.Thread] = None
        self.last_update_id = 0
        self.last_edit_time: Dict[str, float] = {}

    def is_authorized(self, user_id: int) -> bool:
        if not self.admin_ids:
            # If no admin IDs are configured, disallow everyone for security
            return False
        return user_id in self.admin_ids

    def start(self):
        if not self.token:
            return
        self.running = True
        self.poll_thread = threading.Thread(target=self._poll_loop, daemon=True)
        self.poll_thread.start()

    def stop(self):
        self.running = False

    def _poll_loop(self):
        while self.running:
            try:
                res = call_telegram_api(
                    self.token,
                    "getUpdates",
                    {"offset": self.last_update_id + 1, "timeout": 15, "allowed_updates": ["message"]},
                    timeout=20.0,
                )
                if res.get("ok"):
                    for update in res.get("result", []):
                        self.last_update_id = update["update_id"]
                        if "message" in update:
                            self._handle_message(update["message"])
                time.sleep(1)
            except Exception:
                time.sleep(3)

    def _handle_message(self, msg: Dict[str, Any]):
        chat = msg.get("chat", {})
        chat_id = chat.get("id")
        user = msg.get("from", {})
        user_id = user.get("id")
        text = (msg.get("text") or "").strip()

        if not chat_id or not user_id:
            return

        if not self.is_authorized(user_id):
            call_telegram_api(
                self.token,
                "sendMessage",
                {
                    "chat_id": chat_id,
                    "text": f"⛔ <b>Access Denied</b>\n\nYour Telegram User ID: <code>{user_id}</code> is not authorized on this CyberVPS Fleet Controller.",
                    "parse_mode": "HTML",
                },
            )
            return

        # 1. /start and /help
        if text.startswith("/start") or text.startswith("/help"):
            welcome = (
                "⚡ <b>CYBERVPS TRANSFER CLOUD</b>\n\n"
                "Welcome! You can submit download jobs directly to the fleet.\n\n"
                "<b>Commands:</b>\n"
                "• <code>/download &lt;url&gt;</code> — Submit new download job\n"
                "• <code>/jobs</code> — List active and recent transfer jobs\n"
                "• <code>/nodes</code> — View fleet nodes status and metrics\n"
                "• <code>/status</code> — Controller system status\n"
                "• <code>/cancel &lt;job_id&gt;</code> — Cancel an active job\n\n"
                "<i>Tip: You can also simply paste any HTTP/HTTPS URL directly!</i>"
            )
            call_telegram_api(self.token, "sendMessage", {"chat_id": chat_id, "text": welcome, "parse_mode": "HTML"})
            return

        # 2. /nodes
        if text.startswith("/nodes"):
            nodes = self.controller.db.list_nodes()
            if not nodes:
                msg_text = "ℹ No nodes enrolled in CyberFleet."
            else:
                lines = [f"🌐 <b>CyberFleet Nodes ({len(nodes)} total)</b>\n"]
                for n in nodes:
                    status_icon = "🟢" if n["status"] == "ONLINE" else ("🟡" if n["status"] == "DEGRADED" else "🔴")
                    cpu = f"{n.get('effective_cpu', 1.0):.1f} vCPU"
                    ram_mb = n.get("effective_ram_bytes", 0) // (1024**2)
                    disk_gb = n.get("disk_free_bytes", 0) // (1024**3)
                    rx_mbps = (n.get("live_rx_bps", 0.0) * 8) / (1024**2)
                    lines.append(
                        f"{status_icon} <b>{n['name']}</b> ({n['status']})\n"
                        f"   CPU: {cpu} | RAM: {ram_mb} MB | Disk: {disk_gb} GB free\n"
                        f"   Traffic: {rx_mbps:.1f} Mbps | Jobs: {n.get('active_jobs_count', 0)}"
                    )
                msg_text = "\n\n".join(lines)
            call_telegram_api(self.token, "sendMessage", {"chat_id": chat_id, "text": msg_text, "parse_mode": "HTML"})
            return

        # 3. /jobs
        if text.startswith("/jobs"):
            jobs = self.controller.db.list_jobs(limit=10)
            if not jobs:
                msg_text = "ℹ No active or recent transfer jobs."
            else:
                lines = ["📦 <b>Recent Transfer Jobs</b>\n"]
                for j in jobs:
                    icon = "⏳" if j.status in ("QUEUED", "DOWNLOADING") else ("✅" if j.status == "COMPLETED" else "❌")
                    size_mb = j.expected_size // (1024**2) if j.expected_size > 0 else (j.downloaded_bytes // (1024**2))
                    lines.append(
                        f"{icon} <code>{j.id}</code> — <b>{j.filename or 'file'}</b>\n"
                        f"   Status: <b>{j.status}</b> ({j.progress_percent:.0f}%)\n"
                        f"   Size: {size_mb} MB | Node: {j.node_id or 'auto'}"
                    )
                msg_text = "\n\n".join(lines)
            call_telegram_api(self.token, "sendMessage", {"chat_id": chat_id, "text": msg_text, "parse_mode": "HTML"})
            return

        # 4. /download <url> or direct URL pasted
        url_candidate = ""
        if text.startswith("/download"):
            parts = text.split(maxsplit=1)
            if len(parts) > 1:
                url_candidate = parts[1].strip()
        elif text.startswith("http://") or text.startswith("https://"):
            url_candidate = text.split()[0]

        if url_candidate:
            initial_resp = call_telegram_api(
                self.token,
                "sendMessage",
                {
                    "chat_id": chat_id,
                    "text": f"⏳ <b>Probing URL and checking SSRF safety...</b>\n<code>{url_candidate}</code>",
                    "parse_mode": "HTML",
                },
            )
            msg_id = initial_resp.get("result", {}).get("message_id")
            
            # Submit job to controller
            job, err = self.controller.submit_job(
                url=url_candidate,
                telegram_chat_id=chat_id,
                telegram_message_id=msg_id,
            )

            if err or not job:
                call_telegram_api(
                    self.token,
                    "editMessageText",
                    {
                        "chat_id": chat_id,
                        "message_id": msg_id,
                        "text": f"❌ <b>Download Request Rejected</b>\n\n{err or 'Unknown scheduling error'}",
                        "parse_mode": "HTML",
                    },
                )
            else:
                size_str = f"{job.expected_size // (1024**2)} MB" if job.expected_size > 0 else "Unknown size"
                call_telegram_api(
                    self.token,
                    "editMessageText",
                    {
                        "chat_id": chat_id,
                        "message_id": msg_id,
                        "text": (
                            f"⚡ <b>CYBERVPS TRANSFER INTAKE</b>\n\n"
                            f"<b>File:</b> <code>{job.filename}</code>\n"
                            f"<b>Size:</b> {size_str}\n"
                            f"<b>Assigned Node:</b> <code>{job.node_id}</code>\n"
                            f"<b>Status:</b> Initializing download..."
                        ),
                        "parse_mode": "HTML",
                    },
                )
            return

    def update_progress(self, job_id: str, chat_id: int, message_id: int, filename: str, downloaded: int, total: int, speed_bps: float, eta_sec: int, node_name: str):
        """Throttled message editor for live transfer progress bar."""
        now = time.time()
        last = self.last_edit_time.get(job_id, 0.0)
        # Edit at most once every 3 seconds to stay well below Telegram rate limits
        if now - last < 3.0:
            return

        self.last_edit_time[job_id] = now
        pct = (downloaded / total * 100.0) if total > 0 else 0.0
        
        # Render visual bar
        bar_len = 16
        filled = int(round(bar_len * (pct / 100.0)))
        bar = "█" * filled + "░" * (bar_len - filled)
        
        speed_mb = speed_bps / (1024 * 1024)
        dl_mb = downloaded / (1024 * 1024)
        tot_mb = total / (1024 * 1024) if total > 0 else 0

        text = (
            f"⚡ <b>CYBERVPS TRANSFER ACTIVE</b>\n\n"
            f"<b>File:</b> <code>{filename}</code>\n"
            f"<code>[{bar}] {pct:.1f}%</code>\n\n"
            f"<b>Downloaded:</b> {dl_mb:.1f} / {tot_mb:.1f} MB\n"
            f"<b>Speed:</b> {speed_mb:.1f} MiB/s | <b>ETA:</b> {eta_sec}s\n"
            f"<b>Node:</b> <code>{node_name}</code>"
        )

        call_telegram_api(
            self.token,
            "editMessageText",
            {"chat_id": chat_id, "message_id": message_id, "text": text, "parse_mode": "HTML"},
        )

    def notify_completion(self, job_id: str, chat_id: int, message_id: Optional[int], filename: str, file_path: str, file_size: int, sha256: str, direct_link: str, node_name: str):
        """Sends final delivery: direct Telegram upload if <= 50MB, else signed direct link."""
        size_mb = file_size / (1024 * 1024)
        local_p = Path(file_path) if file_path else None
        
        uploaded_doc = False
        # If file is accessible on this host and <= 50MB, attempt direct document upload
        if local_p and local_p.is_file() and file_size <= 50 * 1024 * 1024:
            caption = f"✅ CyberTransfer Complete: {filename} ({size_mb:.1f} MB)"
            up_res = upload_telegram_document(self.token, chat_id, local_p, caption=caption)
            if up_res.get("ok"):
                uploaded_doc = True

        msg = (
            f"🎉 <b>DOWNLOAD COMPLETE</b>\n\n"
            f"<b>File:</b> <code>{filename}</code>\n"
            f"<b>Size:</b> {size_mb:.1f} MB\n"
            f"<b>Node:</b> <code>{node_name}</code>\n"
            f"<b>SHA256:</b> <code>{sha256[:16]}...{sha256[-8:]}</code>\n\n"
            f"🔗 <b>Secure Cybershare Link (Expires in 24h):</b>\n{direct_link}"
        )

        if message_id:
            call_telegram_api(
                self.token,
                "editMessageText",
                {"chat_id": chat_id, "message_id": message_id, "text": msg, "parse_mode": "HTML"},
            )
        else:
            call_telegram_api(
                self.token,
                "sendMessage",
                {"chat_id": chat_id, "text": msg, "parse_mode": "HTML"},
            )
