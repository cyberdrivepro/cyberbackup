package com.cybervps.cybernet.ui

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.widget.*
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.cybervps.cybernet.R
import com.cybervps.cybernet.api.CyberFleetClient
import com.cybervps.cybernet.model.*
import com.cybervps.cybernet.security.KeystoreManager
import com.cybervps.cybernet.service.CyberNetVpnService
import com.google.gson.Gson
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.*

class MainActivity : AppCompatActivity() {

    private lateinit var keystore: KeystoreManager
    private lateinit var client: CyberFleetClient
    private val VPN_REQUEST_CODE = 1001

    private var activeGateways: List<Gateway> = emptyList()
    private var selectedGatewayId: String? = null
    private var selectedProfile: ScoreProfile = ScoreProfile.BALANCED
    private var selectedDnsMode: DnsMode = DnsMode.CLOUDFLARE
    private var killSwitchEnabled: Boolean = false

    private val logEntries = mutableListOf<String>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        keystore = KeystoreManager(this)
        client = CyberFleetClient(keystore)

        renderDynamicLayout()
        appendLog("CyberNet Initialized on Android ${Build.VERSION.RELEASE}")

        // Auto-enroll device if not yet enrolled
        ensureDeviceEnrolled()

        // Periodically refresh gateways and session telemetry
        startTelemetryLoop()
    }

    private fun ensureDeviceEnrolled() {
        if (keystore.getDeviceId() == null) {
            lifecycleScope.launch {
                appendLog("Enrolling device with CyberFleet Controller...")
                val result = client.enrollDevice(Build.MODEL, "Android ${Build.VERSION.RELEASE}")
                result.onSuccess { id ->
                    appendLog("Device enrolled successfully (ID: $id)")
                    loadGateways()
                }.onFailure { err ->
                    appendLog("Enrollment warning: ${err.message}. Retrying on connect.")
                }
            }
        } else {
            appendLog("Device active: ${keystore.getDeviceId()}")
            loadGateways()
        }
    }

    private fun loadGateways() {
        lifecycleScope.launch {
            appendLog("Loading CyberFleet gateways...")
            val result = client.getGateways(selectedProfile)
            result.onSuccess { list ->
                activeGateways = list
                appendLog("${list.size} gateways available from CyberFleet")
                updateServerListView()
            }.onFailure { err ->
                appendLog("Failed to fetch gateways: ${err.message}")
            }
        }
    }

    private fun toggleVpnConnection() {
        if (CyberNetVpnService.isRunning.get()) {
            appendLog("Disconnecting VPN...")
            val intent = Intent(this, CyberNetVpnService::class.java).apply {
                action = CyberNetVpnService.ACTION_DISCONNECT
            }
            startService(intent)
            updateHomeView(connected = false)
        } else {
            val vpnIntent = VpnService.prepare(this)
            if (vpnIntent != null) {
                startActivityForResult(vpnIntent, VPN_REQUEST_CODE)
            } else {
                onActivityResult(VPN_REQUEST_CODE, Activity.RESULT_OK, null)
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_REQUEST_CODE && resultCode == Activity.RESULT_OK) {
            initiateVpnSession()
        } else {
            appendLog("VPN permission rejected by user")
        }
    }

    private fun initiateVpnSession() {
        val devId = keystore.getDeviceId() ?: "dev_anonymous"
        lifecycleScope.launch {
            appendLog("Requesting VPN session (Profile: ${selectedProfile.name})...")
            val result = client.createSession(
                deviceId = devId,
                protocol = "AUTO",
                profile = selectedProfile,
                gatewayId = selectedGatewayId,
                dnsMode = selectedDnsMode,
                fullTunnel = true
            )

            result.onSuccess { sessionResp ->
                appendLog("Session granted: ${sessionResp.session_id}")
                appendLog("Selected Gateway: ${sessionResp.gateway_name} (${sessionResp.gateway_region})")
                appendLog("Assigned Virtual IP: ${sessionResp.assigned_ip}")
                appendLog("Protocol: ${sessionResp.protocol}")
                appendLog("Configuring Android VpnService TUN interface...")

                val intent = Intent(this@MainActivity, CyberNetVpnService::class.java).apply {
                    action = CyberNetVpnService.ACTION_CONNECT
                    putExtra(CyberNetVpnService.EXTRA_SESSION_DATA, Gson().toJson(sessionResp))
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(intent)
                } else {
                    startService(intent)
                }

                updateHomeView(connected = true, gatewayName = sessionResp.gateway_name)
            }.onFailure { err ->
                appendLog("Session negotiation failed: ${err.message}")
            }
        }
    }

    private fun startTelemetryLoop() {
        lifecycleScope.launch {
            while (true) {
                delay(3000)
                if (CyberNetVpnService.isRunning.get()) {
                    updateHomeView(
                        connected = true,
                        gatewayName = CyberNetVpnService.activeGatewayName,
                        rxBytes = CyberNetVpnService.totalBytesRx,
                        txBytes = CyberNetVpnService.totalBytesTx
                    )
                }
            }
        }
    }

    private fun appendLog(msg: String) {
        val timeStr = SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(Date())
        val entry = "[$timeStr] $msg"
        logEntries.add(entry)
        val logsTv = findViewById<TextView?>(R.id.tv_logs_content)
        logsTv?.append("$entry\n")
    }

    private fun updateHomeView(
        connected: Boolean,
        gatewayName: String = "AUTO SELECT",
        rxBytes: Long = 0,
        txBytes: Long = 0
    ) {
        val statusPill = findViewById<TextView?>(R.id.tv_status_pill) ?: return
        val btnConnect = findViewById<Button?>(R.id.btn_connect_action) ?: return
        val tvGw = findViewById<TextView?>(R.id.tv_active_gateway) ?: return
        val tvTraffic = findViewById<TextView?>(R.id.tv_traffic_stat) ?: return

        if (connected) {
            statusPill.text = "● CONNECTED"
            statusPill.setTextColor(0xFF00FF88.toInt())
            btnConnect.text = "DISCONNECT"
            tvGw.text = gatewayName
            val mbRx = rxBytes / (1024.0 * 1024.0)
            val mbTx = txBytes / (1024.0 * 1024.0)
            tvTraffic.text = "↓ ${String.format("%.1f", mbRx)} MB  ↑ ${String.format("%.1f", mbTx)} MB"
        } else {
            statusPill.text = "○ DISCONNECTED"
            statusPill.setTextColor(0xFF94A3B8.toInt())
            btnConnect.text = "CONNECT"
            tvGw.text = "AUTO SELECT"
            tvTraffic.text = "↓ 0.0 MB  ↑ 0.0 MB"
        }
    }

    private fun updateServerListView() {
        val serverListLayout = findViewById<LinearLayout?>(R.id.ll_server_list) ?: return
        serverListLayout.removeAllViews()

        for (gw in activeGateways) {
            val itemBtn = Button(this).apply {
                text = "${gw.node_name} (${gw.region}) • ${gw.latency_ms.toInt()}ms • Score: ${gw.gateway_score}"
                setBackgroundColor(0xFF111622.toInt())
                setTextColor(0xFFF0F4F8.toInt())
                setOnClickListener {
                    selectedGatewayId = gw.node_id
                    appendLog("Selected manual gateway: ${gw.node_name}")
                    Toast.makeText(this@MainActivity, "Gateway: ${gw.node_name}", Toast.LENGTH_SHORT).show()
                }
            }
            serverListLayout.addView(itemBtn)
        }
    }

    private fun renderDynamicLayout() {
        val root = ScrollView(this).apply {
            setBackgroundColor(0xFF0A0D14.toInt())
            setPadding(32, 48, 32, 48)
        }

        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }

        // Header Title
        val title = TextView(this).apply {
            text = "CYBERNET"
            textSize = 24f
            setTextColor(0xFF00F0FF.toInt())
            paint.isFakeBoldText = true
            setPadding(0, 0, 0, 16)
        }
        container.addView(title)

        // Status Card
        val statusCard = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(0xFF111622.toInt())
            setPadding(32, 32, 32, 32)
        }

        val statusPill = TextView(this).apply {
            id = R.id.tv_status_pill
            text = "○ DISCONNECTED"
            textSize = 18f
            setTextColor(0xFF94A3B8.toInt())
            paint.isFakeBoldText = true
        }
        statusCard.addView(statusPill)

        val gwLabel = TextView(this).apply {
            id = R.id.tv_active_gateway
            text = "AUTO SELECT"
            textSize = 14f
            setTextColor(0xFFF0F4F8.toInt())
            setPadding(0, 8, 0, 8)
        }
        statusCard.addView(gwLabel)

        val trafficLabel = TextView(this).apply {
            id = R.id.tv_traffic_stat
            text = "↓ 0.0 MB  ↑ 0.0 MB"
            textSize = 13f
            setTextColor(0xFF00F0FF.toInt())
        }
        statusCard.addView(trafficLabel)

        val btnConnect = Button(this).apply {
            id = R.id.btn_connect_action
            text = "CONNECT"
            setBackgroundColor(0xFF00F0FF.toInt())
            setTextColor(0xFF0A0D14.toInt())
            setOnClickListener { toggleVpnConnection() }
        }
        statusCard.addView(btnConnect)
        container.addView(statusCard)

        // Gateways List Section
        val gwsHeader = TextView(this).apply {
            text = "Available Gateways"
            textSize = 16f
            setTextColor(0xFFF0F4F8.toInt())
            setPadding(0, 24, 0, 8)
        }
        container.addView(gwsHeader)

        val serverListLayout = LinearLayout(this).apply {
            id = R.id.ll_server_list
            orientation = LinearLayout.VERTICAL
        }
        container.addView(serverListLayout)

        // Event Logs Section
        val logsHeader = TextView(this).apply {
            text = "Diagnostics & Security Logs"
            textSize = 16f
            setTextColor(0xFFF0F4F8.toInt())
            setPadding(0, 24, 0, 8)
        }
        container.addView(logsHeader)

        val logsView = TextView(this).apply {
            id = R.id.tv_logs_content
            textSize = 11f
            setTextColor(0xFF94A3B8.toInt())
            setBackgroundColor(0xFF05070A.toInt())
            setPadding(16, 16, 16, 16)
        }
        container.addView(logsView)

        root.addView(container)
        setContentView(root)
    }
}
