package com.cybervps.cybernet.model

enum class ScoreProfile {
    BALANCED,
    LOW_LATENCY,
    MAX_THROUGHPUT,
    STREAMING,
    MANUAL
}

enum class TunnelProtocol {
    WIREGUARD,
    SSH_TUN2SOCKS
}

enum class DnsMode {
    CLOUDFLARE,
    GOOGLE,
    QUAD9,
    SYSTEM,
    CUSTOM
}

data class Gateway(
    val node_id: String,
    val node_name: String,
    val region: String,
    val ipv4_address: String,
    val latency_ms: Float,
    val packet_loss: Float,
    val active_sessions: Int,
    val gateway_score: Float,
    val wireguard_enabled: Boolean,
    val ssh_enabled: Boolean,
    val last_benchmark_dl_bps: Double = 0.0,
    val is_favorite: Boolean = false
)

data class BackupGateway(
    val gateway_id: String,
    val name: String,
    val region: String,
    val endpoint: String,
    val latency_ms: Float,
    val score: Float
)

data class SessionResponse(
    val session_id: String,
    val gateway_id: String,
    val gateway_name: String,
    val gateway_region: String,
    val protocol: String,
    val assigned_ip: String,
    val dns_servers: List<String>,
    val wireguard_config: String?,
    val ssh_config: Map<String, Any>?,
    val backup_gateways: List<BackupGateway>
)

data class LiveTrafficStats(
    val rxBytes: Long,
    val txBytes: Long,
    val rxSpeedBps: Double,
    val txSpeedBps: Double,
    val latencyMs: Float,
    val packetLossPct: Float
)

data class CyberTransferJob(
    val id: String,
    val url: String,
    val filename: String,
    val mode: String,
    val status: String,
    val progressPercent: Float,
    val currentSpeedBps: Double,
    val downloadedBytes: Long,
    val totalBytes: Long,
    val assemblerNode: String?
)

data class CyberShareLink(
    val token: String,
    val filename: String,
    val file_size: Long,
    val url: String,
    val expires_at: Long
)
