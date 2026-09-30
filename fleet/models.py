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
    node_id: Optional[str] = None
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
