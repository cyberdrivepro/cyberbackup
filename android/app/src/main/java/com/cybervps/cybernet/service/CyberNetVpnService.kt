package com.cybervps.cybernet.service

import android.app.*
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.core.app.NotificationCompat
import com.cybervps.cybernet.R
import com.cybervps.cybernet.api.CyberFleetClient
import com.cybervps.cybernet.model.BackupGateway
import com.cybervps.cybernet.model.SessionResponse
import com.cybervps.cybernet.security.KeystoreManager
import kotlinx.coroutines.*
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicBoolean

class CyberNetVpnService : VpnService() {

    companion object {
        const val ACTION_CONNECT = "com.cybervps.cybernet.CONNECT"
        const val ACTION_DISCONNECT = "com.cybervps.cybernet.DISCONNECT"
        const val EXTRA_SESSION_DATA = "extra_session_data"
        const val NOTIFICATION_ID = 4040
        const val CHANNEL_ID = "cybernet_vpn_channel"

        val isRunning = AtomicBoolean(false)
        var activeGatewayName: String = "Unknown"
        var activeLatencyMs: Float = 0f
        var totalBytesRx: Long = 0
        var totalBytesTx: Long = 0
    }

    private var vpnInterface: ParcelFileDescriptor? = null
    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private lateinit var client: CyberFleetClient
    private lateinit var keystore: KeystoreManager
    private var currentSessionId: String? = null
    private var backupGateways: List<BackupGateway> = emptyList()

    override fun onCreate() {
        super.onCreate()
        keystore = KeystoreManager(this)
        client = CyberFleetClient(keystore)
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_DISCONNECT -> {
                disconnectVpn("User disconnected")
                stopSelf()
            }
            ACTION_CONNECT -> {
                val sessionJson = intent.getStringExtra(EXTRA_SESSION_DATA)
                if (sessionJson != null) {
                    val gson = com.google.gson.Gson()
                    val sessionResp = gson.fromJson(sessionJson, SessionResponse::class.java)
                    startVpn(sessionResp)
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun startVpn(session: SessionResponse) {
        currentSessionId = session.session_id
        activeGatewayName = session.gateway_name
        backupGateways = session.backup_gateways

        startForeground(NOTIFICATION_ID, buildNotification("Connecting to ${session.gateway_name}..."))

        serviceScope.launch {
            try {
                val builder = Builder()
                    .setSession("CyberNet: ${session.gateway_name}")
                    .addAddress(session.assigned_ip, 32)
                    .addRoute("0.0.0.0", 0)

                // Add configured DNS servers
                for (dns in session.dns_servers) {
                    try {
                        builder.addDnsServer(dns)
                    } catch (_: Exception) {}
                }

                // Optional IPv6 route if supported
                try {
                    builder.addRoute("::", 0)
                } catch (_: Exception) {}

                builder.setMtu(1420)
                builder.setBlocking(true)

                // Per-app routing package configuration
                val prefs = getSharedPreferences("cybernet_routing_prefs", MODE_PRIVATE)
                val routeMode = prefs.getString("routing_mode", "ALL") // ALL, INCLUDE, EXCLUDE
                val selectedApps = prefs.getStringSet("selected_apps", emptySet()) ?: emptySet()

                if (routeMode == "INCLUDE" && selectedApps.isNotEmpty()) {
                    for (pkg in selectedApps) {
                        try { builder.addAllowedApplication(pkg) } catch (_: Exception) {}
                    }
                } else if (routeMode == "EXCLUDE" && selectedApps.isNotEmpty()) {
                    for (pkg in selectedApps) {
                        try { builder.addDisallowedApplication(pkg) } catch (_: Exception) {}
                    }
                }

                vpnInterface = builder.establish()
                if (vpnInterface == null) {
                    disconnectVpn("Failed to establish TUN interface")
                    return@launch
                }

                isRunning.set(true)
                updateNotification()

                // Launch tunnel worker loop
                launchTrafficWorker(vpnInterface!!)

                // Launch periodic heartbeat & failover monitor
                launchHealthMonitor()

            } catch (e: Exception) {
                disconnectVpn("TUN establishment error: ${e.message}")
            }
        }
    }

    private fun launchTrafficWorker(pfd: ParcelFileDescriptor) {
        serviceScope.launch {
            val inputStream = FileInputStream(pfd.fileDescriptor)
            val outputStream = FileOutputStream(pfd.fileDescriptor)
            val buffer = ByteArray(32768)

            try {
                while (isRunning.get()) {
                    val read = inputStream.read(buffer)
                    if (read > 0) {
                        totalBytesTx += read
                        // In actual WireGuard-Go/Tun2Socks integration, packets route to peer socket
                    }
                }
            } catch (_: Exception) {
            } finally {
                try { inputStream.close() } catch (_: Exception) {}
                try { outputStream.close() } catch (_: Exception) {}
            }
        }
    }

    private fun launchHealthMonitor() {
        serviceScope.launch {
            while (isRunning.get()) {
                delay(5000)
                val sId = currentSessionId ?: continue
                try {
                    client.sendHeartbeat(sId, totalBytesRx, totalBytesTx)
                    updateNotification()
                } catch (e: Exception) {
                    // Possible gateway unreachable -> trigger auto-failover
                    attemptAutoFailover()
                }
            }
        }
    }

    private suspend fun attemptAutoFailover() {
        if (backupGateways.isEmpty()) return
        val nextGw = backupGateways.first()
        backupGateways = backupGateways.drop(1)

        val sId = currentSessionId ?: return
        val switched = client.switchSession(sId, nextGw.gateway_id)
        if (switched.getOrDefault(false)) {
            activeGatewayName = nextGw.name
            activeLatencyMs = nextGw.latency_ms
            updateNotification()
        }
    }

    private fun disconnectVpn(reason: String) {
        isRunning.set(false)
        try {
            vpnInterface?.close()
            vpnInterface = null
        } catch (_: Exception) {}

        currentSessionId?.let { sId ->
            serviceScope.launch {
                client.terminateSession(sId)
            }
        }
        stopForeground(true)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "CyberNet VPN Status",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows live gateway and traffic stats"
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(statusText: String): Notification {
        val disconnectIntent = PendingIntent.getService(
            this,
            0,
            Intent(this, CyberNetVpnService::class.java).apply { action = ACTION_DISCONNECT },
            PendingIntent.FLAG_IMMUTABLE
        )

        val mbRx = totalBytesRx / (1024.0 * 1024.0)
        val mbTx = totalBytesTx / (1024.0 * 1024.0)

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("CyberNet: $activeGatewayName")
            .setContentText("$statusText | ↓ ${String.format("%.1f", mbRx)}MB ↑ ${String.format("%.1f", mbTx)}MB")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Disconnect", disconnectIntent)
            .build()
    }

    private fun updateNotification() {
        if (!isRunning.get()) return
        val notification = buildNotification("Protected")
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, notification)
    }

    override fun onDestroy() {
        disconnectVpn("Service destroyed")
        serviceScope.cancel()
        super.onDestroy()
    }
}
