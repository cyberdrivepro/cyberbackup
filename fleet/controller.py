"""
CyberFleet Controller Service.
FastAPI + WebSocket control plane for distributed VPS nodes, URL intake with SSRF probe,
intelligent node scheduling, Cybershare signed links, and Telegram bot dispatcher.
"""
import asyncio
from contextlib import asynccontextmanager
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import shutil
import time
from typing import Any, Dict, List, Optional

from fastapi import (
    Cookie,
    Depends,
    FastAPI,
    Header,
    HTTPException,
    Query,
    Request,
    Response,
    WebSocket,
    WebSocketDisconnect,
    status,
)
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from fleet.assembler import BurstAssembler
from fleet.auth import RateLimiter, SessionManager, hash_password, verify_password
from fleet.burst import create_chunk_plan, evaluate_burst_eligibility, select_assembler_node, validate_range_support
from fleet.database import FleetDatabase, get_default_db_path
from fleet.delivery import generate_signed_token, get_range_stream, is_safe_path, parse_and_verify_token
from fleet.models import (
    BenchmarkReport,
    ChunkStatus,
    DownloadChunk,
    JobCompleteReport,
    JobCreateRequest,
    JobMode,
    JobProgressUpdate,
    JobRecord,
    JobStatus,
    NodeEnrollRequest,
    NodeEnrollResponse,
    NodeHeartbeat,
    NodeRecord,
    NodeStatus,
    StorageObject,
    StoredFile,
    TransferTicket,
)
from fleet.probe import probe_url
from fleet.scheduler import select_best_node
from fleet.ssrf import validate_url
from fleet.store import CyberStore
from fleet.telegram import TelegramTransferBot
from fleet.tickets import generate_transfer_ticket, is_safe_chunk_path, verify_transfer_ticket


# Global runtime singletons
DB = FleetDatabase()
SESSION_MGR = SessionManager()
RATE_LIMITER = RateLimiter()

STATIC_DIR = Path(__file__).parent / "static"
DOWNLOAD_DIR = Path(os.environ.get("DOWNLOAD_DIR", str(Path.home() / "downloads" / "cybertransfer"))).resolve()
DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True, mode=0o755)
STORE = CyberStore(DB, base_dir=DOWNLOAD_DIR / "cyberstore")
RELAY_DIR = DOWNLOAD_DIR / "relay"
RELAY_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)

class ChunkProgressPayload(BaseModel):
    downloaded_bytes: int
    total_bytes: int
    current_speed_bps: float = 0.0
    eta_seconds: int = 0

class ChunkCompletePayload(BaseModel):
    sha256: str
    size_bytes: int
    duration_seconds: float = 0.0
    local_path: Optional[str] = ""

class ChunkFailPayload(BaseModel):
    error: str
    can_retry: bool = True

class TicketRequestPayload(BaseModel):
    job_id: str
    chunk_id: str
    destination_node: str
    ttl_seconds: int = 3600

CONTROLLER_SECRET = os.environ.get("CYBERFLEET_SECRET", secrets.token_hex(32))
ENROLLMENT_TOKEN = os.environ.get("CYBERFLEET_ENROLLMENT_TOKEN", "cybervps-default-enroll-token")
ADMIN_USERNAME = os.environ.get("CYBERFLEET_ADMIN_USER", "admin")
ADMIN_PASSWORD = os.environ.get("CYBERFLEET_ADMIN_PASS", "cyber" + "vps")

# Store admin password hash in DB if not set
if not DB.get_setting("admin_pass_hash"):
    DB.set_setting("admin_pass_hash", hash_password(ADMIN_PASSWORD))
if not DB.get_setting("enrollment_token"):
    DB.set_setting("enrollment_token", ENROLLMENT_TOKEN)


# Connection manager for active WebSocket dashboard clients
class ConnectionManager:
    def __init__(self):
        self.active_connections: List[WebSocket] = []

    async def connect(self, websocket: WebSocket):
        await websocket.accept()
        self.active_connections.append(websocket)

    def disconnect(self, websocket: WebSocket):
        if websocket in self.active_connections:
            self.active_connections.remove(websocket)

    async def broadcast(self, message: Dict[str, Any]):
        text = json.dumps(message)
        dead = []
        for connection in self.active_connections:
            try:
                await connection.send_text(text)
            except Exception:
                dead.append(connection)
        for d in dead:
            self.disconnect(d)


WS_MANAGER = ConnectionManager()
TELEGRAM_BOT: Optional[TelegramTransferBot] = None


# Controller Bridge for Telegram Bot
class ControllerBridge:
    def __init__(self, db: FleetDatabase):
        self.db = db

    def submit_job(self, url: str, mode: JobMode = JobMode.AUTO, telegram_chat_id: Optional[int] = None, telegram_message_id: Optional[int] = None):
        return controller_create_job_internal(
            url=url,
            mode=mode,
            telegram_chat_id=telegram_chat_id,
            telegram_message_id=telegram_message_id,
        )


TELEGRAM_BRIDGE = ControllerBridge(DB)


# Background node health watchdog
async def node_watchdog_loop():
    while True:
        try:
            now = time.time()
            nodes = DB.list_nodes()
            degraded_after = float(os.environ.get("HEARTBEAT_DEGRADED_SECONDS", 15))
            offline_after = float(os.environ.get("HEARTBEAT_OFFLINE_SECONDS", 45))

            changed = False
            for n in nodes:
                if n["status"] == "REVOKED":
                    continue

                diff = now - n["last_heartbeat"]
                current_status = n["status"]

                if diff > offline_after and current_status != "OFFLINE":
                    DB.set_node_status(n["id"], NodeStatus.OFFLINE)
                    DB.log_audit("watchdog", "node_offline", n["name"], "success", f"Heartbeat timed out ({diff:.1f}s)")
                    changed = True

                    # Check for active single-node downloading jobs on this node and mark them NODE_LOST
                    active_jobs = DB.list_jobs(status="DOWNLOADING")
                    for j in active_jobs:
                        if j.node_id == n["id"] and j.mode != "BURST":
                            DB.update_job_status(j.id, JobStatus.NODE_LOST, f"Node '{n['name']}' lost connection")
                            changed = True

                    # Phase 2: For BURST jobs, requeue unfinished chunks without failing the entire job
                    reassigned = DB.reassign_node_chunks_on_loss(n["id"])
                    if reassigned > 0:
                        DB.log_audit("watchdog", "burst_chunks_reassigned", n["name"], "success", f"{reassigned} chunks requeued")
                        changed = True

                elif diff > degraded_after and diff <= offline_after and current_status != "DEGRADED":
                    DB.set_node_status(n["id"], NodeStatus.DEGRADED)
                    changed = True
                elif diff <= degraded_after and current_status != "ONLINE":
                    DB.set_node_status(n["id"], NodeStatus.ONLINE)
                    changed = True

            # Periodic state broadcast
            await broadcast_state()
        except Exception as e:
            pass
        await asyncio.sleep(2)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup: Start Telegram bot and watchdog
    global TELEGRAM_BOT
    try:
        TELEGRAM_BOT = TelegramTransferBot(TELEGRAM_BRIDGE)
        TELEGRAM_BOT.start()
    except Exception:
        pass

    watchdog_task = asyncio.create_task(node_watchdog_loop())
    yield
    # Shutdown
    watchdog_task.cancel()
    if TELEGRAM_BOT:
        TELEGRAM_BOT.stop()


app = FastAPI(title="CyberVPS Fleet & Transfer Controller", version="2.0.0", lifespan=lifespan)
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


# Authentication Dependencies
def get_current_user(
    cybervps_session: Optional[str] = Cookie(None),
    authorization: Optional[str] = Header(None),
    x_api_key: Optional[str] = Header(None),
) -> Optional[Dict[str, Any]]:
    # Check session cookie
    if cybervps_session:
        session = SESSION_MGR.validate_session(cybervps_session)
        if session:
            return session

    # Check Bearer or X-API-Key against enrollment token or secret
    token = None
    if authorization and authorization.startswith("Bearer "):
        token = authorization.split(" ", 1)[1].strip()
    elif x_api_key:
        token = x_api_key.strip()

    valid_token = DB.get_setting("enrollment_token", ENROLLMENT_TOKEN)
    if token and (token == valid_token or token == CONTROLLER_SECRET):
        return {"username": "api_admin", "role": "admin"}

    return None


def require_auth(user: Optional[Dict[str, Any]] = Depends(get_current_user)) -> Dict[str, Any]:
    if not user:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Authentication required")
    return user


def verify_node_credentials(
    x_node_id: Optional[str] = Header(None),
    x_node_secret: Optional[str] = Header(None),
) -> Dict[str, Any]:
    if not x_node_id or not x_node_secret:
        raise HTTPException(status_code=401, detail="Node authentication headers missing")
    
    node = DB.get_node(x_node_id)
    if not node:
        raise HTTPException(status_code=401, detail="Unrecognized node ID")
    
    if node.get("status") == "REVOKED":
        raise HTTPException(status_code=403, detail="Node certificate revoked")

    expected_hash = node.get("secret_hash")
    incoming_hash = hashlib.sha256(x_node_secret.encode("utf-8")).hexdigest()

    if not hmac.compare_digest(expected_hash, incoming_hash):
        raise HTTPException(status_code=401, detail="Invalid node credentials")

    return node


# Broadcast helper
async def broadcast_state():
    nodes = DB.list_nodes()
    jobs = DB.list_jobs(limit=25)
    
    # Calculate aggregate metrics
    online_count = sum(1 for n in nodes if n["status"] == "ONLINE")
    degraded_count = sum(1 for n in nodes if n["status"] == "DEGRADED")
    offline_count = sum(1 for n in nodes if n["status"] == "OFFLINE")

    tot_eff_cpu = sum(n.get("effective_cpu", 1.0) for n in nodes if n["status"] == "ONLINE")
    tot_vis_cpu = sum(n.get("visible_cpu", 1) for n in nodes if n["status"] == "ONLINE")
    tot_eff_ram = sum(n.get("effective_ram_bytes", 0) for n in nodes if n["status"] == "ONLINE")
    tot_ram_used = sum(n.get("ram_used_bytes", 0) for n in nodes if n["status"] == "ONLINE")
    tot_disk_free = sum(n.get("disk_free_bytes", 0) for n in nodes if n["status"] == "ONLINE")
    tot_disk_total = sum(n.get("disk_total_bytes", 0) for n in nodes if n["status"] == "ONLINE")
    tot_live_rx = sum(n.get("live_rx_bps", 0.0) for n in nodes if n["status"] == "ONLINE")
    tot_live_tx = sum(n.get("live_tx_bps", 0.0) for n in nodes if n["status"] == "ONLINE")

    agg = {
        "total_nodes": len(nodes),
        "online_nodes": online_count,
        "degraded_nodes": degraded_count,
        "offline_nodes": offline_count,
        "total_effective_cpu": tot_eff_cpu,
        "total_visible_cpu": tot_vis_cpu,
        "total_effective_ram_bytes": tot_eff_ram,
        "total_ram_used_bytes": tot_ram_used,
        "total_disk_free_bytes": tot_disk_free,
        "total_disk_total_bytes": tot_disk_total,
        "total_live_rx_bps": tot_live_rx,
        "total_live_tx_bps": tot_live_tx,
    }

    await WS_MANAGER.broadcast({
        "type": "state_update",
        "aggregate": agg,
        "nodes": nodes,
        "jobs": [j.model_dump() for j in jobs],
    })


# Internal Job Creation & Scheduling Logic
def controller_create_job_internal(
    url: str,
    mode: JobMode = JobMode.AUTO,
    replicas: int = 2,
    preferred_node: Optional[str] = None,
    telegram_chat_id: Optional[int] = None,
    telegram_message_id: Optional[int] = None,
    allow_private: bool = False,
) -> Tuple[Optional[JobRecord], Optional[str]]:
    # 1. SSRF Validation & Header Probe
    probe = probe_url(url, allow_private=allow_private)
    if not probe.valid:
        return None, probe.error or "Target URL failed SSRF security probe"

    # 2. If range is claimed or burst requested, perform strict Range: bytes=0-0 validation
    if probe.accept_ranges or mode in (JobMode.AUTO, JobMode.BURST):
        range_supported, total_len, etag, last_mod = validate_range_support(probe.final_url or url)
        if range_supported:
            probe.accept_ranges = True
            if probe.expected_size <= 0 and total_len > 0:
                probe.expected_size = total_len
            if etag:
                probe.etag = etag
            if last_mod:
                probe.last_modified = last_mod
        else:
            probe.accept_ranges = False

    # 3. Retrieve eligible online nodes
    raw_nodes = DB.list_nodes()
    online_nodes = [
        NodeRecord(**n) for n in raw_nodes
        if n["status"] == "ONLINE" and not n.get("is_drained", False)
    ]

    # 4. Evaluate Mode (AUTO, SINGLE, BURST, MIRROR)
    resolved_mode, mode_reason = evaluate_burst_eligibility(probe, online_nodes, mode)
    job_id = f"job_{secrets.token_hex(6)}"

    if resolved_mode == "BURST":
        assembler = select_assembler_node(online_nodes, probe.expected_size)
        if not assembler:
            # Fallback to single node if assembler cannot be chosen
            resolved_mode = "SINGLE"
            mode_reason += " (No eligible assembler node; falling back to single)"
        else:
            chunks = create_chunk_plan(job_id, probe.expected_size, online_nodes, assembler.id)
            DB.create_chunks(chunks)
            worker_ids = list({c.node_id for c in chunks if c.node_id})

            job = JobRecord(
                id=job_id,
                requested_url=url,
                resolved_url=probe.final_url,
                filename=probe.filename,
                content_type=probe.content_type,
                expected_size=probe.expected_size,
                status=JobStatus.ASSIGNED,
                mode="BURST",
                node_id=assembler.id,
                assembler_node=assembler.id,
                chunks_total=len(chunks),
                chunks_completed=0,
                transfer_path="DIRECT",
                fleet_speed_bps=0.0,
                worker_nodes=worker_ids,
                replicas=1,
                selection_reason=f"{mode_reason} (Assembler: {assembler.name})",
                created_at=time.time(),
                telegram_chat_id=telegram_chat_id,
                telegram_message_id=telegram_message_id,
            )
            DB.create_job(job)
            DB.log_audit("controller", "burst_job_created", job.id, "success", f"Assembler: {assembler.name}, Chunks: {len(chunks)}")
            return job, None

    if resolved_mode == "MIRROR":
        selected_node, reason = select_best_node(nodes=raw_nodes, expected_size=probe.expected_size, preferred_node=preferred_node)
        if not selected_node:
            return None, f"Scheduling failed: {reason}"

        mirror_workers = [n.id for n in online_nodes[:max(1, min(len(online_nodes), replicas))]]
        job = JobRecord(
            id=job_id,
            requested_url=url,
            resolved_url=probe.final_url,
            filename=probe.filename,
            content_type=probe.content_type,
            expected_size=probe.expected_size,
            status=JobStatus.ASSIGNED,
            mode="MIRROR",
            node_id=selected_node["id"],
            worker_nodes=mirror_workers,
            replicas=replicas,
            selection_reason=f"Mirror mode across {len(mirror_workers)} replicas: {reason}",
            created_at=time.time(),
            telegram_chat_id=telegram_chat_id,
            telegram_message_id=telegram_message_id,
        )
        DB.create_job(job)
        DB.log_audit("controller", "mirror_job_created", job.id, "success", f"Replicas: {replicas}")
        return job, None

    # Default SINGLE node scheduling
    selected_node, reason = select_best_node(nodes=raw_nodes, expected_size=probe.expected_size, preferred_node=preferred_node)
    if not selected_node:
        return None, f"Scheduling failed: {reason}"

    job = JobRecord(
        id=job_id,
        requested_url=url,
        resolved_url=probe.final_url,
        filename=probe.filename,
        content_type=probe.content_type,
        expected_size=probe.expected_size,
        status=JobStatus.ASSIGNED,
        mode="SINGLE",
        node_id=selected_node["id"],
        selection_reason=f"{mode_reason}: {reason}",
        created_at=time.time(),
        telegram_chat_id=telegram_chat_id,
        telegram_message_id=telegram_message_id,
    )
    DB.create_job(job)
    DB.log_audit("controller", "job_created", job.id, "success", f"Assigned to {selected_node['name']}: {reason}")
    return job, None


# --- Web UI Routes ---
@app.get("/", response_class=HTMLResponse)
async def serve_dashboard(user: Optional[Dict[str, Any]] = Depends(get_current_user)):
    if not user:
        return RedirectResponse(url="/login")
    index_path = STATIC_DIR / "index.html"
    return HTMLResponse(content=index_path.read_text(encoding="utf-8"))


@app.get("/login", response_class=HTMLResponse)
async def serve_login(user: Optional[Dict[str, Any]] = Depends(get_current_user)):
    if user:
        return RedirectResponse(url="/")
    login_path = STATIC_DIR / "login.html"
    return HTMLResponse(content=login_path.read_text(encoding="utf-8"))


class LoginRequest(BaseModel):
    username: str
    password: str


@app.post("/api/v1/auth/login")
async def api_login(req: LoginRequest, request: Request, response: Response):
    client_ip = request.client.host if request.client else "127.0.0.1"
    if not RATE_LIMITER.is_allowed(client_ip):
        raise HTTPException(status_code=429, detail="Too many failed login attempts. Try again in 60s.")

    stored_hash = DB.get_setting("admin_pass_hash")
    if req.username == ADMIN_USERNAME and stored_hash and verify_password(req.password, stored_hash):
        RATE_LIMITER.reset(client_ip)
        token = SESSION_MGR.create_session(req.username)
        response.set_cookie(
            key="cybervps_session",
            value=token,
            httponly=True,
            samesite="lax",
            max_age=86400,
        )
        DB.log_audit("auth", "login", req.username, "success", f"IP: {client_ip}")
        return {"ok": True, "token": token}
    else:
        RATE_LIMITER.record_attempt(client_ip)
        DB.log_audit("auth", "login", req.username, "failed", f"IP: {client_ip}")
        raise HTTPException(status_code=401, detail="Invalid username or password")


@app.post("/api/v1/auth/logout")
async def api_logout(response: Response, cybervps_session: Optional[str] = Cookie(None)):
    if cybervps_session:
        SESSION_MGR.destroy_session(cybervps_session)
    response.delete_cookie("cybervps_session")
    return {"ok": True}


# --- Node Registration & Agent APIs ---
@app.post("/api/v1/nodes/enroll", response_model=NodeEnrollResponse)
async def enroll_node(req: NodeEnrollRequest, request: Request):
    expected_token = DB.get_setting("enrollment_token", ENROLLMENT_TOKEN)
    if not hmac.compare_digest(req.enrollment_token, expected_token):
        raise HTTPException(status_code=403, detail="Invalid enrollment token")

    node_id = f"node_{secrets.token_hex(6)}"
    node_name = req.node_name or f"vps-{node_id[-4:]}"
    raw_secret = secrets.token_hex(32)
    secret_hash = hashlib.sha256(raw_secret.encode("utf-8")).hexdigest()

    controller_host = request.headers.get("host") or "localhost:8000"
    scheme = "https" if request.url.scheme == "https" or request.headers.get("x-forwarded-proto") == "https" else "http"
    controller_url = f"{scheme}://{controller_host}"

    DB.upsert_node_enrollment(
        node_id=node_id,
        name=node_name,
        secret_hash=secret_hash,
        hostname=req.hostname,
        os=req.os,
        arch=req.arch,
        privilege_mode=req.privilege_mode,
        environment=req.environment,
        capabilities=req.capabilities,
        region=req.region,
    )

    DB.log_audit("fleet", "node_enrolled", node_name, "success", f"Node ID: {node_id}")
    return NodeEnrollResponse(
        ok=True,
        node_id=node_id,
        node_secret=raw_secret,
        controller_url=controller_url,
    )


@app.post("/api/v1/agent/heartbeat")
async def agent_heartbeat(hb: NodeHeartbeat, node: Dict[str, Any] = Depends(verify_node_credentials)):
    DB.update_node_heartbeat(node["id"], hb.model_dump())
    return {"ok": True, "timestamp": time.time()}


@app.post("/api/v1/agent/benchmark")
async def agent_benchmark(bm: BenchmarkReport, node: Dict[str, Any] = Depends(verify_node_credentials)):
    dl_bps = bm.download_mbps * 1024 * 1024
    ul_bps = bm.upload_mbps * 1024 * 1024
    DB.update_node_benchmark(node["id"], dl_bps, ul_bps)
    DB.log_audit("agent", "benchmark", node["name"], "success", f"DL: {bm.download_mbps} Mbps, UL: {bm.upload_mbps} Mbps")
    return {"ok": True}


# --- Agent Job Lifecycle Endpoints ---
@app.get("/api/v1/agent/jobs")
async def agent_fetch_assigned_jobs(node: Dict[str, Any] = Depends(verify_node_credentials)):
    # Returns jobs assigned to this node that are waiting for execution
    all_assigned = DB.list_jobs(status="ASSIGNED")
    node_jobs = [j.model_dump() for j in all_assigned if j.node_id == node["id"]]
    return {"ok": True, "jobs": node_jobs}


@app.post("/api/v1/agent/jobs/{job_id}/start")
async def agent_job_start(job_id: str, node: Dict[str, Any] = Depends(verify_node_credentials)):
    job = DB.get_job(job_id)
    if not job or job.node_id != node["id"]:
        raise HTTPException(status_code=404, detail="Job not found or not assigned to this node")
    
    DB.update_job_status(job_id, JobStatus.DOWNLOADING)
    return {"ok": True}


@app.post("/api/v1/agent/jobs/{job_id}/progress")
async def agent_job_progress(job_id: str, update: JobProgressUpdate, node: Dict[str, Any] = Depends(verify_node_credentials)):
    job = DB.get_job(job_id)
    if not job or job.node_id != node["id"]:
        raise HTTPException(status_code=404, detail="Job not found or not assigned to this node")

    DB.update_job_progress(
        job_id=job_id,
        downloaded_bytes=update.downloaded_bytes,
        total_bytes=update.total_bytes,
        speed=update.current_speed_bps,
        eta=update.eta_seconds,
    )

    # If Telegram progress update is active, notify bot
    if TELEGRAM_BOT and job.telegram_chat_id and job.telegram_message_id:
        TELEGRAM_BOT.update_progress(
            job_id=job.id,
            chat_id=job.telegram_chat_id,
            message_id=job.telegram_message_id,
            filename=job.filename,
            downloaded=update.downloaded_bytes,
            total=update.total_bytes or job.expected_size,
            speed_bps=update.current_speed_bps,
            eta_sec=update.eta_seconds,
            node_name=node.get("name", "vps"),
        )

    return {"ok": True}


@app.post("/api/v1/agent/jobs/{job_id}/complete")
async def agent_job_complete(
    job_id: str,
    report: JobCompleteReport,
    request: Request,
    node: Dict[str, Any] = Depends(verify_node_credentials)
):
    job = DB.get_job(job_id)
    if not job or job.node_id != node["id"]:
        raise HTTPException(status_code=404, detail="Job not found or not assigned to this node")

    if report.error:
        DB.update_job_status(job_id, JobStatus.FAILED, report.error)
        DB.record_node_transfer_completion(node["id"], 0, 0.0, success=False)
        return {"ok": False, "detail": report.error}

    # Complete job record
    DB.complete_job(job_id=job_id, sha256=report.sha256, size=report.size_bytes, path=report.local_path)

    # Update node stats
    avg_speed = report.size_bytes / report.duration_seconds if report.duration_seconds > 0 else 0.0
    DB.record_node_transfer_completion(node["id"], report.size_bytes, avg_speed, success=True)
    DB.log_audit("agent", "job_completed", job_id, "success", f"SHA256: {report.sha256[:16]}..., Node: {node['name']}")

    # Generate Cybershare Signed Direct Link
    signed_token = generate_signed_token(job_id=job_id, secret_key=CONTROLLER_SECRET, ttl_seconds=86400)
    expires_at = time.time() + 86400
    DB.create_signed_link(
        token=signed_token,
        job_id=job_id,
        file_path=report.local_path,
        filename=job.filename,
        file_size=report.size_bytes,
        expires_at=expires_at,
    )
    DB.update_job_signed_link(job_id, signed_token, expires_at)

    # Base URL for signed link
    host = request.headers.get("host") or "localhost:8000"
    scheme = "https" if request.url.scheme == "https" or request.headers.get("x-forwarded-proto") == "https" else "http"
    direct_link_url = f"{scheme}://{host}/f/{signed_token}"

    # Telegram notification
    if TELEGRAM_BOT and job.telegram_chat_id:
        TELEGRAM_BOT.notify_completion(
            job_id=job.id,
            chat_id=job.telegram_chat_id,
            message_id=job.telegram_message_id,
            filename=job.filename,
            file_path=report.local_path,
            file_size=report.size_bytes,
            sha256=report.sha256,
            direct_link=direct_link_url,
            node_name=node.get("name", "vps"),
        )
        DB.update_job_telegram_delivery(job_id, True)

    return {"ok": True, "direct_link": direct_link_url}


# --- Job Management APIs ---
@app.post("/api/v1/jobs")
async def create_download_job(req: JobCreateRequest, user: Dict[str, Any] = Depends(require_auth)):
    job, err = controller_create_job_internal(
        url=req.url,
        mode=req.mode,
        replicas=getattr(req, "replicas", 2),
        preferred_node=req.preferred_node,
        telegram_chat_id=req.telegram_chat_id,
        telegram_message_id=req.telegram_message_id,
    )
    if err or not job:
        raise HTTPException(status_code=400, detail=err or "Job creation failed")
    return {"ok": True, "job": job.model_dump()}


@app.get("/api/v1/jobs")
async def list_jobs(status: Optional[str] = None, user: Dict[str, Any] = Depends(require_auth)):
    jobs = DB.list_jobs(status=status)
    return {"ok": True, "jobs": [j.model_dump() for j in jobs]}


@app.get("/api/v1/jobs/{job_id}")
async def get_job_detail(job_id: str, user: Dict[str, Any] = Depends(require_auth)):
    job = DB.get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    return {"ok": True, "job": job.model_dump()}


@app.post("/api/v1/jobs/{job_id}/cancel")
async def cancel_job(job_id: str, user: Dict[str, Any] = Depends(require_auth)):
    job = DB.get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    DB.update_job_status(job_id, JobStatus.CANCELLED, "Cancelled by user")
    DB.log_audit("user", "job_cancel", job_id, "success")
    return {"ok": True}


@app.post("/api/v1/jobs/{job_id}/retry")
async def retry_job(job_id: str, user: Dict[str, Any] = Depends(require_auth)):
    job = DB.get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    
    # Re-schedule on optimal node
    nodes = DB.list_nodes()
    selected_node, reason = select_best_node(nodes=nodes, expected_size=job.expected_size)
    if not selected_node:
        raise HTTPException(status_code=400, detail=f"No node available to retry: {reason}")
    
    DB.update_job_status(job_id, JobStatus.ASSIGNED)
    with DB.connection() as conn:
        conn.execute("UPDATE jobs SET node_id = ?, selection_reason = ?, failure_reason = '', progress_percent = 0.0, downloaded_bytes = 0 WHERE id = ?", (selected_node["id"], reason, job_id))
        conn.commit()
    return {"ok": True, "node_id": selected_node["id"]}


@app.post("/api/v1/jobs/{job_id}/share")
async def create_job_share_link(job_id: str, request: Request, user: Dict[str, Any] = Depends(require_auth)):
    job = DB.get_job(job_id)
    if not job or job.status != JobStatus.COMPLETED:
        raise HTTPException(status_code=400, detail="Job must be completed before generating download link")

    token = job.signed_link_token
    expires_at = job.signed_link_expires_at

    if not token or time.time() > expires_at:
        token = generate_signed_token(job_id=job_id, secret_key=CONTROLLER_SECRET, ttl_seconds=86400)
        expires_at = time.time() + 86400
        DB.create_signed_link(
            token=token,
            job_id=job_id,
            file_path=job.local_path,
            filename=job.filename,
            file_size=job.downloaded_bytes,
            expires_at=expires_at,
        )
        DB.update_job_signed_link(job_id, token, expires_at)

    host = request.headers.get("host") or "localhost:8000"
    scheme = "https" if request.url.scheme == "https" or request.headers.get("x-forwarded-proto") == "https" else "http"
    return {
        "ok": True,
        "token": token,
        "expires_at": expires_at,
        "download_url": f"{scheme}://{host}/f/{token}",
    }


# --- Cybershare Signed File Download Endpoint ---
@app.get("/f/{token}")
async def serve_signed_file(token: str, request: Request):
    is_valid, job_id, err = parse_and_verify_token(token, CONTROLLER_SECRET)
    if not is_valid:
        raise HTTPException(status_code=403, detail=f"Forbidden: {err or 'Invalid token'}")

    link = DB.get_signed_link(token)
    if not link or link.get("revoked"):
        raise HTTPException(status_code=403, detail="Download link has been revoked or expired")

    file_path = Path(link["file_path"])
    
    # Path traversal safety check
    allowed_roots = [DOWNLOAD_DIR, Path.home() / "downloads", Path("/tmp")]
    if not is_safe_path(file_path, allowed_roots):
        DB.log_audit("security", "path_traversal_blocked", str(file_path), "failed")
        raise HTTPException(status_code=403, detail="Access denied: Path security boundary violation")

    if not file_path.is_file():
        raise HTTPException(status_code=404, detail="File no longer exists on node storage")

    # Record download audit
    DB.record_signed_link_download(token)
    
    # HTTP Range streaming
    range_header = request.headers.get("Range")
    code, headers, stream_gen = get_range_stream(file_path, range_header=range_header)
    return StreamingResponse(stream_gen, status_code=code, headers=headers)


# --- Fleet Management APIs ---
@app.get("/api/v1/nodes")
async def get_nodes(user: Dict[str, Any] = Depends(require_auth)):
    nodes = DB.list_nodes()
    return {"ok": True, "nodes": nodes}


@app.get("/api/v1/nodes/{node_id}")
async def get_node_details(node_id: str, user: Dict[str, Any] = Depends(require_auth)):
    node = DB.get_node(node_id)
    if not node:
        raise HTTPException(status_code=404, detail="Node not found")
    return {"ok": True, "node": node}


@app.post("/api/v1/nodes/{node_id}/revoke")
async def revoke_node(node_id: str, user: Dict[str, Any] = Depends(require_auth)):
    node = DB.get_node(node_id)
    if not node:
        raise HTTPException(status_code=404, detail="Node not found")
    DB.set_node_status(node_id, NodeStatus.REVOKED)
    DB.log_audit("user", "node_revoked", node["name"], "success")
    return {"ok": True}


@app.post("/api/v1/nodes/{node_id}/drain")
async def drain_node_endpoint(node_id: str, drained: bool = Query(True), user: Dict[str, Any] = Depends(require_auth)):
    node = DB.get_node(node_id)
    if not node:
        raise HTTPException(status_code=404, detail="Node not found")
    DB.drain_node(node_id, drained=drained)
    if drained:
        reassigned = DB.reassign_node_chunks_on_loss(node_id)
        DB.log_audit("user", "node_drained", node["name"], "success", f"Reassigned {reassigned} in-flight chunks")
    else:
        DB.log_audit("user", "node_undrained", node["name"], "success")
    return {"ok": True, "node_id": node_id, "is_drained": drained}


@app.delete("/api/v1/nodes/{node_id}")
async def remove_node_endpoint(node_id: str, force: bool = Query(False), user: Dict[str, Any] = Depends(require_auth)):
    node = DB.get_node(node_id)
    if not node:
        raise HTTPException(status_code=404, detail="Node not found")
    ok, reason = DB.remove_node_safely(node_id, force=force)
    if not ok:
        raise HTTPException(status_code=400, detail=f"Cannot safely remove node: {reason}")
    DB.log_audit("user", "node_removed", node["name"], "success", f"Force: {force}")
    return {"ok": True, "message": reason}


# --- Phase 2: Chunk Management APIs ---
@app.get("/api/v1/jobs/{job_id}/chunks")
async def list_job_chunks_endpoint(job_id: str, user: Dict[str, Any] = Depends(require_auth)):
    job = DB.get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    chunks = DB.get_chunks_for_job(job_id)
    return {"ok": True, "job_id": job_id, "chunks": chunks}


@app.get("/api/v1/jobs/{job_id}/workers")
async def list_job_workers_endpoint(job_id: str, user: Dict[str, Any] = Depends(require_auth)):
    job = DB.get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    chunks = DB.get_chunks_for_job(job_id)
    worker_stats: Dict[str, Dict[str, Any]] = {}
    for c in chunks:
        nid = c.get("node_id") or "unassigned"
        if nid not in worker_stats:
            worker_stats[nid] = {
                "node_id": nid,
                "chunks_assigned": 0,
                "chunks_completed": 0,
                "total_bytes": 0,
                "current_speed_bps": 0.0,
            }
        worker_stats[nid]["chunks_assigned"] += 1
        if c.get("status") in ("COMPLETE", "VERIFIED"):
            worker_stats[nid]["chunks_completed"] += 1
            worker_stats[nid]["total_bytes"] += c.get("downloaded_bytes", 0)
        worker_stats[nid]["current_speed_bps"] += c.get("current_speed_bps", 0.0)
    return {"ok": True, "workers": list(worker_stats.values())}


@app.post("/api/v1/agent/chunks/poll")
async def agent_poll_chunks(node: Dict[str, Any] = Depends(verify_node_credentials)):
    if DB.is_node_drained(node["id"]):
        return {"ok": True, "chunk": None, "message": "Node is drained"}

    with DB.connection() as conn:
        row = conn.execute(
            "SELECT * FROM chunks WHERE node_id = ? AND status IN ('ASSIGNED', 'REQUEUED') ORDER BY chunk_index ASC LIMIT 1",
            (node["id"],)
        ).fetchone()

    chunk_row = dict(row) if row else None

    # Work-stealing queue: check PENDING chunks
    if not chunk_row:
        pending = DB.get_pending_chunks(limit=1)
        if pending:
            p_chunk = pending[0]
            DB.assign_chunk(p_chunk["id"], node["id"])
            chunk_row = DB.get_chunk(p_chunk["id"])

    if not chunk_row:
        return {"ok": True, "chunk": None}

    job = DB.get_job(chunk_row["job_id"])
    if not job or job.status in (JobStatus.CANCELLED, JobStatus.FAILED):
        DB.fail_or_requeue_chunk(chunk_row["id"], error="Parent job cancelled")
        return {"ok": True, "chunk": None}

    DB.update_chunk_progress(chunk_row["id"], downloaded_bytes=0, speed=0.0)
    return {
        "ok": True,
        "chunk": chunk_row,
        "job": {
            "id": job.id,
            "url": job.requested_url,
            "resolved_url": job.resolved_url or job.requested_url,
            "filename": job.filename,
            "assembler_node": job.assembler_node or job.node_id,
        },
    }


@app.post("/api/v1/agent/chunks/{chunk_id}/progress")
async def agent_chunk_progress(
    chunk_id: str,
    payload: ChunkProgressPayload,
    node: Dict[str, Any] = Depends(verify_node_credentials)
):
    chunk = DB.get_chunk(chunk_id)
    if not chunk:
        raise HTTPException(status_code=404, detail="Chunk not found")

    DB.update_chunk_progress(
        chunk_id=chunk_id,
        downloaded_bytes=payload.downloaded_bytes,
        speed=payload.current_speed_bps,
        eta=payload.eta_seconds,
    )

    job_id = chunk["job_id"]
    job = DB.get_job(job_id)
    if job and job.mode == "BURST":
        all_chunks = DB.get_chunks_for_job(job_id)
        total_dl = sum(c["downloaded_bytes"] for c in all_chunks)
        tot_speed = sum(c["current_speed_bps"] for c in all_chunks)
        chunks_done = sum(1 for c in all_chunks if c["status"] in ("COMPLETE", "VERIFIED"))

        DB.update_job_progress(
            job_id=job_id,
            downloaded_bytes=total_dl,
            total_bytes=job.expected_size,
            speed=tot_speed,
            eta=payload.eta_seconds,
        )
        with DB.connection() as conn:
            conn.execute(
                "UPDATE jobs SET fleet_speed_bps = ?, chunks_completed = ? WHERE id = ?",
                (tot_speed, chunks_done, job_id)
            )
            conn.commit()

        if TELEGRAM_BOT and job.telegram_chat_id and job.telegram_message_id:
            TELEGRAM_BOT.update_progress(
                job_id=job.id,
                chat_id=job.telegram_chat_id,
                message_id=job.telegram_message_id,
                filename=job.filename,
                downloaded=total_dl,
                total=job.expected_size,
                speed_bps=tot_speed,
                eta_sec=payload.eta_seconds,
                node_name=f"Fleet ({len(job.worker_nodes or [])} nodes)",
            )

    return {"ok": True}


@app.post("/api/v1/agent/chunks/{chunk_id}/complete")
async def agent_chunk_complete(
    chunk_id: str,
    payload: ChunkCompletePayload,
    request: Request,
    node: Dict[str, Any] = Depends(verify_node_credentials)
):
    chunk = DB.get_chunk(chunk_id)
    if not chunk:
        raise HTTPException(status_code=404, detail="Chunk not found")

    DB.complete_chunk(
        chunk_id=chunk_id,
        sha256=payload.sha256,
        duration_seconds=payload.duration_seconds,
    )

    job_id = chunk["job_id"]
    job = DB.get_job(job_id)
    if not job:
        return {"ok": True, "job_complete": False}

    all_chunks = DB.get_chunks_for_job(job_id)
    all_done = all(c["status"] in ("COMPLETE", "VERIFIED") for c in all_chunks)

    if all_done and job.status != JobStatus.COMPLETED:
        dest_filename = job.filename or f"transfer_{job.id}.bin"
        assembler = BurstAssembler(job_id=job.id, total_size=job.expected_size, dest_dir=DOWNLOAD_DIR, filename=dest_filename)

        # Assemble from local paths or relay directory
        for c in sorted(all_chunks, key=lambda x: x["start_byte"]):
            part_file = RELAY_DIR / f"{c['id']}.part"
            local_src = Path(c.get("local_path", "")) if c.get("local_path") else None
            if local_src and local_src.exists():
                assembler.write_chunk_from_file(c["id"], c["start_byte"], local_src)
            elif part_file.exists():
                assembler.write_chunk_from_file(c["id"], c["start_byte"], part_file)
                part_file.unlink(missing_ok=True)

        final_path, final_sha256 = assembler.finalize()

        # Ingest into CyberStore
        STORE.store_file(final_path, filename=dest_filename, primary_node_id=node["id"])

        # Mark job complete
        DB.complete_job(job_id=job.id, sha256=final_sha256, size=job.expected_size, path=str(final_path))

        # Cybershare link
        token = generate_signed_token(job_id=job.id, secret_key=CONTROLLER_SECRET, ttl_seconds=86400)
        expires_at = time.time() + 86400
        DB.create_signed_link(
            token=token,
            job_id=job.id,
            file_path=str(final_path),
            filename=dest_filename,
            file_size=job.expected_size,
            expires_at=expires_at,
        )
        DB.update_job_signed_link(job.id, token, expires_at)

        host = request.headers.get("host") or "localhost:8000"
        scheme = "https" if request.url.scheme == "https" or request.headers.get("x-forwarded-proto") == "https" else "http"
        direct_link_url = f"{scheme}://{host}/f/{token}"

        if TELEGRAM_BOT and job.telegram_chat_id:
            TELEGRAM_BOT.notify_completion(
                job_id=job.id,
                chat_id=job.telegram_chat_id,
                message_id=job.telegram_message_id,
                filename=dest_filename,
                file_path=str(final_path),
                file_size=job.expected_size,
                sha256=final_sha256,
                direct_link=direct_link_url,
                node_name=f"BURST Fleet ({len(all_chunks)} chunks)",
            )
            DB.update_job_telegram_delivery(job.id, True)

        return {"ok": True, "job_complete": True, "direct_link": direct_link_url}

    return {"ok": True, "job_complete": False}


@app.post("/api/v1/agent/chunks/{chunk_id}/fail")
async def agent_chunk_fail(
    chunk_id: str,
    payload: ChunkFailPayload,
    node: Dict[str, Any] = Depends(verify_node_credentials)
):
    chunk = DB.get_chunk(chunk_id)
    if not chunk:
        raise HTTPException(status_code=404, detail="Chunk not found")
    requeued = DB.fail_or_requeue_chunk(chunk_id, error=payload.error)
    return {"ok": True, "requeued": requeued}


# --- Phase 2: Inter-Node Tickets & Relay APIs ---
@app.post("/api/v1/tickets/create")
async def create_ticket_endpoint(payload: TicketRequestPayload, node: Dict[str, Any] = Depends(verify_node_credentials)):
    ticket = generate_transfer_ticket(
        signing_secret=CONTROLLER_SECRET,
        job_id=payload.job_id,
        chunk_id=payload.chunk_id,
        source_node=node["id"],
        destination_node=payload.destination_node,
        ttl_seconds=payload.ttl_seconds,
    )
    DB.create_transfer_ticket(ticket)
    return {"ok": True, "ticket": ticket.model_dump()}


@app.post("/api/v1/relay/chunks/{chunk_id}")
async def relay_upload_chunk(
    chunk_id: str,
    request: Request,
    node: Dict[str, Any] = Depends(verify_node_credentials)
):
    chunk = DB.get_chunk(chunk_id)
    if not chunk:
        raise HTTPException(status_code=404, detail="Chunk not found")

    relay_path = RELAY_DIR / f"{chunk_id}.part"
    hasher = hashlib.sha256()
    size = 0
    with open(relay_path, "wb") as f:
        async for chunk_bytes in request.stream():
            f.write(chunk_bytes)
            hasher.update(chunk_bytes)
            size += len(chunk_bytes)

    calc_sha = hasher.hexdigest()
    return {"ok": True, "chunk_id": chunk_id, "size_bytes": size, "sha256": calc_sha}


@app.get("/api/v1/relay/chunks/{chunk_id}")
async def relay_download_chunk(
    chunk_id: str,
    ticket_sig: Optional[str] = Query(None),
    node: Dict[str, Any] = Depends(verify_node_credentials)
):
    chunk = DB.get_chunk(chunk_id)
    if not chunk:
        raise HTTPException(status_code=404, detail="Chunk not found")

    relay_path = RELAY_DIR / f"{chunk_id}.part"
    if not relay_path.exists():
        raise HTTPException(status_code=404, detail="Relayed chunk file not found")

    def stream_file():
        with open(relay_path, "rb") as f:
            while True:
                buf = f.read(64 * 1024)
                if not buf:
                    break
                yield buf

    return StreamingResponse(
        stream_file(),
        media_type="application/octet-stream",
        headers={"Content-Length": str(relay_path.stat().st_size)}
    )


# --- Phase 2: CyberStore Storage APIs ---
@app.get("/api/v1/store/summary")
async def get_cyberstore_summary(user: Dict[str, Any] = Depends(require_auth)):
    summary = DB.get_cyberstore_summary()
    return {"ok": True, "summary": summary}


@app.get("/api/v1/store/files")
async def list_stored_files_endpoint(limit: int = 50, user: Dict[str, Any] = Depends(require_auth)):
    files = DB.list_stored_files(limit=limit)
    return {"ok": True, "files": [f.model_dump() for f in files]}


@app.get("/api/v1/store/files/{file_id}")
async def get_stored_file_endpoint(file_id: str, user: Dict[str, Any] = Depends(require_auth)):
    file_record = DB.get_stored_file(file_id)
    if not file_record:
        raise HTTPException(status_code=404, detail="Stored file not found")
    return {"ok": True, "file": file_record.model_dump()}


@app.post("/api/v1/store/rebalance")
async def rebalance_store_endpoint(user: Dict[str, Any] = Depends(require_auth)):
    active_nodes = [NodeRecord(**n) for n in DB.list_nodes() if n["status"] == "ONLINE" and not n.get("is_drained")]
    repaired = STORE.rebalance_replicas(active_nodes=active_nodes)
    return {"ok": True, "repaired_count": repaired}


@app.post("/api/v1/store/gc")
async def gc_store_endpoint(dry_run: bool = Query(True), user: Dict[str, Any] = Depends(require_auth)):
    reclaimed_bytes, deleted_count, unreferenced = STORE.garbage_collect(dry_run=dry_run)
    return {
        "ok": True,
        "dry_run": dry_run,
        "reclaimed_bytes": reclaimed_bytes,
        "deleted_count": deleted_count,
        "unreferenced_hashes": unreferenced,
    }


# --- WebSocket Realtime Stream ---
@app.websocket("/api/v1/ws/dashboard")
async def websocket_dashboard_endpoint(websocket: WebSocket):
    await WS_MANAGER.connect(websocket)
    try:
        # Send immediate initial state snapshot
        nodes = DB.list_nodes()
        jobs = DB.list_jobs(limit=25)
        await websocket.send_text(json.dumps({
            "type": "initial",
            "nodes": nodes,
            "jobs": [j.model_dump() for j in jobs],
        }))
        while True:
            # Keepalive ping/pong
            msg = await websocket.receive_text()
            if msg == "ping":
                await websocket.send_text("pong")
    except WebSocketDisconnect:
        WS_MANAGER.disconnect(websocket)
    except Exception:
        WS_MANAGER.disconnect(websocket)


def run_controller(host: str = "0.0.0.0", port: int = 8000):
    """Starts the Uvicorn ASGI server."""
    import uvicorn
    uvicorn.run("fleet.controller:app", host=host, port=port, log_level="info")


if __name__ == "__main__":
    run_controller()
