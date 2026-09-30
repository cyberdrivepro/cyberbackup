"""
Data models and state definitions for CyberFleet and CyberTransfer.
"""
from enum import Enum
import time
from typing import Any, Dict, List, Optional
from pydantic import BaseModel, Field


class NodeStatus(str, Enum):
    ONLINE = "ONLINE"
    DEGRADED = "DEGRADED"
    OFFLINE = "OFFLINE"
    REVOKED = "REVOKED"


class JobStatus(str, Enum):
    QUEUED = "QUEUED"
    PROBING = "PROBING"
    SCHEDULING = "SCHEDULING"
    ASSIGNED = "ASSIGNED"
    DOWNLOADING = "DOWNLOADING"
    VERIFYING = "VERIFYING"
    DELIVERING = "DELIVERING"
    COMPLETED = "COMPLETED"
    RETRYING = "RETRYING"
    PAUSED = "PAUSED"
    CANCELLED = "CANCELLED"
    FAILED = "FAILED"
    NODE_LOST = "NODE_LOST"
    SOURCE_CHANGED = "SOURCE_CHANGED"


class JobMode(str, Enum):
    AUTO = "AUTO"
    SINGLE = "SINGLE"
    BURST = "BURST"
    MIRROR = "MIRROR"


class ChunkStatus(str, Enum):
    PENDING = "PENDING"
    ASSIGNED = "ASSIGNED"
    DOWNLOADING = "DOWNLOADING"
    COMPLETE = "COMPLETE"
    RETRYING = "RETRYING"
    FAILED = "FAILED"
    REQUEUED = "REQUEUED"
    VERIFIED = "VERIFIED"


class NodeEnrollRequest(BaseModel):
    enrollment_token: str
    node_name: Optional[str] = None
    hostname: str = "unknown"
    os: str = "linux"
    arch: str = "x86_64"
    privilege_mode: str = "ROOTLESS"
    environment: str = "vps"
    capabilities: Dict[str, Any] = Field(default_factory=dict)
    region: Optional[str] = None


class NodeEnrollResponse(BaseModel):
    ok: bool
    node_id: str
    node_secret: str
    controller_url: str
    message: str = "Enrolled successfully"


class NodeHeartbeat(BaseModel):
    node_id: str
    timestamp: float = Field(default_factory=time.time)
    agent_version: str = "2.0.0"
    hostname: str = "unknown"
    os: str = "linux"
    arch: str = "x86_64"
    environment: str = "vps"
    privilege_mode: str = "ROOTLESS"
    uptime_seconds: float = 0.0
    active_jobs_count: int = 0
    agent_status: str = "IDLE"
    
    # Effective resource metrics
    effective_cpu: float = 1.0
    visible_cpu: int = 1
    effective_ram_bytes: int = 0
    visible_ram_bytes: int = 0
    ram_used_bytes: int = 0
    disk_total_bytes: int = 0
    disk_free_bytes: int = 0
    
    # Live network metrics (EMA)
    live_rx_bps: float = 0.0
    live_tx_bps: float = 0.0
    
    capabilities: Dict[str, Any] = Field(default_factory=dict)
    region: Optional[str] = None


class NodeRecord(BaseModel):
    id: str
    name: str
    hostname: str = "unknown"
    os: str = "linux"
    arch: str = "x86_64"
    privilege_mode: str = "ROOTLESS"
    environment: str = "vps"
    status: NodeStatus = NodeStatus.ONLINE
    agent_version: str = "2.0.0"
    enrolled_at: float = Field(default_factory=time.time)
    last_heartbeat: float = Field(default_factory=time.time)
    
    effective_cpu: float = 1.0
    visible_cpu: int = 1
    effective_ram_bytes: int = 0
    visible_ram_bytes: int = 0
    ram_used_bytes: int = 0
    disk_total_bytes: int = 0
    disk_free_bytes: int = 0
    
    live_rx_bps: float = 0.0
    live_tx_bps: float = 0.0
    last_benchmark_dl_bps: float = 0.0
    last_benchmark_ul_bps: float = 0.0
    benchmark_timestamp: float = 0.0
    
    recent_avg_speed_bps: float = 0.0
    recent_peak_speed_bps: float = 0.0
    total_bytes_transferred: int = 0
    active_jobs_count: int = 0
    reliability_score: float = 100.0
    failure_count: int = 0
    success_count: int = 0
    is_drained: bool = False
    storage_used_bytes: int = 0
    
    capabilities: Dict[str, Any] = Field(default_factory=dict)
    region: Optional[str] = None


class ProbeResult(BaseModel):
    valid: bool
    url: str
    final_url: str
    http_status: int = 0
    content_type: str = "application/octet-stream"
    expected_size: int = 0
    accept_ranges: bool = False
    etag: str = ""
    last_modified: str = ""
    filename: str = ""
    error: Optional[str] = None


class JobCreateRequest(BaseModel):
    url: str
    filename: Optional[str] = None
    mode: JobMode = JobMode.AUTO
    replicas: int = 2
    telegram_chat_id: Optional[int] = None
    telegram_message_id: Optional[int] = None
    preferred_node: Optional[str] = None


class JobRecord(BaseModel):
    id: str
    requested_url: str
    resolved_url: str = ""
    filename: str = ""
    content_type: str = "application/octet-stream"
    expected_size: int = 0
    downloaded_bytes: int = 0
    progress_percent: float = 0.0
    current_speed_bps: float = 0.0
    peak_speed_bps: float = 0.0
    average_speed_bps: float = 0.0
    eta_seconds: int = 0
    status: JobStatus = JobStatus.QUEUED
    mode: str = "SINGLE"
    node_id: Optional[str] = None
    assembler_node: Optional[str] = None
    chunks_total: int = 0
    chunks_completed: int = 0
    transfer_path: str = "DIRECT"
    fleet_speed_bps: float = 0.0
    worker_nodes: List[str] = Field(default_factory=list)
    replicas: int = 1
    selection_reason: str = ""
    sha256: str = ""
    local_path: str = ""
    created_at: float = Field(default_factory=time.time)
    started_at: float = 0.0
    completed_at: float = 0.0
    retry_count: int = 0
    max_retries: int = 3
    failure_reason: str = ""
    telegram_chat_id: Optional[int] = None
    telegram_message_id: Optional[int] = None
    telegram_delivered: bool = False
    signed_link_token: str = ""
    signed_link_expires_at: float = 0.0


class DownloadChunk(BaseModel):
    chunk_id: str
    job_id: str
    chunk_index: int
    start_byte: int
    end_byte: int
    expected_length: int
    downloaded_bytes: int = 0
    node_id: Optional[str] = None
    status: ChunkStatus = ChunkStatus.PENDING
    attempt_count: int = 0
    checksum: str = ""
    speed_bps: float = 0.0
    created_at: float = Field(default_factory=time.time)
    started_at: float = 0.0
    completed_at: float = 0.0
    local_path: str = ""

    @property
    def byte_length(self) -> int:
        return self.expected_length


class TransferTicket(BaseModel):
    ticket_id: str
    job_id: str
    chunk_id: str
    source_node: str
    destination_node: str
    expires_at: float
    nonce: str
    signature: str
    used: bool = False


class StorageObject(BaseModel):
    object_hash: str
    size_bytes: int
    reference_count: int = 1
    created_at: float = Field(default_factory=time.time)
    last_accessed_at: float = Field(default_factory=time.time)
    pinned: bool = False


class StorageReplica(BaseModel):
    object_hash: str
    node_id: str
    local_rel_path: str
    size_bytes: int
    is_healthy: bool = True
    stored_at: float = Field(default_factory=time.time)


class StoredFile(BaseModel):
    file_id: str
    filename: str
    size_bytes: int
    final_hash: str
    replication_factor: int = 2
    created_at: float = Field(default_factory=time.time)
    status: str = "HEALTHY"


class StoredFileChunk(BaseModel):
    file_id: str
    chunk_index: int
    object_hash: str
    start_byte: int
    end_byte: int


class JobProgressUpdate(BaseModel):
    downloaded_bytes: int
    total_bytes: int = 0
    current_speed_bps: float = 0.0
    eta_seconds: int = 0
    status: Optional[str] = None


class JobCompleteReport(BaseModel):
    sha256: str
    size_bytes: int
    duration_seconds: float
    local_path: str
    error: Optional[str] = None


class BenchmarkReport(BaseModel):
    download_mbps: float
    upload_mbps: float
    provider: str = "internal"
    duration_seconds: float = 5.0


# =====================================================================
# Phase 3: CyberNet Full-Device VPN & Mobile Control Models
# =====================================================================

class CyberNetScoreProfile(str, Enum):
    BALANCED = "BALANCED"
    LOW_LATENCY = "LOW_LATENCY"
    MAX_THROUGHPUT = "MAX_THROUGHPUT"
    STREAMING = "STREAMING"
    MANUAL = "MANUAL"


class CyberNetDeviceStatus(str, Enum):
    ACTIVE = "ACTIVE"
    REVOKED = "REVOKED"


class CyberNetProtocol(str, Enum):
    WIREGUARD = "WIREGUARD"
    SSH_TUN2SOCKS = "SSH_TUN2SOCKS"


class CyberNetSessionStatus(str, Enum):
    ACTIVE = "ACTIVE"
    TERMINATED = "TERMINATED"
    FAILED_OVER = "FAILED_OVER"


class CyberNetDevice(BaseModel):
    id: str
    name: str
    device_type: str = "android"
    os_version: str = "Android 15"
    public_key: str
    status: CyberNetDeviceStatus = CyberNetDeviceStatus.ACTIVE
    enrolled_at: float = Field(default_factory=time.time)
    last_seen_at: float = Field(default_factory=time.time)
    auth_token_hash: str


class CyberNetGatewayInfo(BaseModel):
    node_id: str
    enabled: bool = True
    wireguard_enabled: bool = True
    wireguard_port: int = 51820
    wireguard_public_key: str = ""
    wireguard_subnet: str = "10.66.0.0/24"
    ssh_enabled: bool = True
    ssh_port: int = 22
    udp_supported: bool = True
    ipv4_address: str = ""
    ipv6_address: Optional[str] = None
    region: str = "NL"
    latency_ms: float = 0.0
    packet_loss: float = 0.0
    active_sessions: int = 0
    tunnel_rx_bytes: int = 0
    tunnel_tx_bytes: int = 0
    gateway_score: float = 0.0


class CyberNetSessionRecord(BaseModel):
    session_id: str
    device_id: str
    gateway_node_id: str
    protocol: CyberNetProtocol = CyberNetProtocol.WIREGUARD
    assigned_ip: str = "10.66.0.2"
    start_time: float = Field(default_factory=time.time)
    end_time: Optional[float] = None
    status: CyberNetSessionStatus = CyberNetSessionStatus.ACTIVE
    bytes_rx: int = 0
    bytes_tx: int = 0
    disconnect_reason: Optional[str] = None


class CyberNetEnrollRequest(BaseModel):
    name: str
    device_type: str = "android"
    os_version: str = "Android 15"
    public_key: str


class CyberNetSessionRequest(BaseModel):
    device_id: str
    protocol: Optional[str] = "AUTO"
    score_profile: str = "BALANCED"
    gateway_id: Optional[str] = None
    dns_mode: str = "CLOUDFLARE"
    custom_dns: Optional[str] = None
    full_tunnel: bool = True


class CyberNetSessionResponse(BaseModel):
    session_id: str
    gateway_id: str
    gateway_name: str
    gateway_region: str
    protocol: str
    assigned_ip: str
    dns_servers: List[str]
    wireguard_config: Optional[str] = None
    ssh_config: Optional[Dict[str, Any]] = None
    backup_gateways: List[Dict[str, Any]] = Field(default_factory=list)

