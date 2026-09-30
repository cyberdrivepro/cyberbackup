package com.cybervps.cybernet.ui

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.cybervps.cybernet.api.CyberFleetClient
import com.cybervps.cybernet.security.KeystoreManager
import kotlinx.coroutines.launch

class ShareActivity : AppCompatActivity() {

    private lateinit var client: CyberFleetClient
    private var sharedUrl: String = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val keystore = KeystoreManager(this)
        client = CyberFleetClient(keystore)

        if (intent?.action == Intent.ACTION_SEND && intent.type == "text/plain") {
            sharedUrl = intent.getStringExtra(Intent.EXTRA_TEXT) ?: ""
        }

        if (sharedUrl.isBlank() || (!sharedUrl.startsWith("http://") && !sharedUrl.startsWith("https://"))) {
            Toast.makeText(this, "No valid HTTP/HTTPS URL found in share content", Toast.LENGTH_SHORT).show()
            finish()
            return
        }

        renderShareDialog()
    }

    private fun renderShareDialog() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(0xFF111622.toInt())
            setPadding(32, 32, 32, 32)
        }

        val title = TextView(this).apply {
            text = "⚡ CyberTransfer Fleet Share"
            textSize = 18f
            setTextColor(0xFF00F0FF.toInt())
            paint.isFakeBoldText = true
            setPadding(0, 0, 0, 16)
        }
        root.addView(title)

        val urlPreview = TextView(this).apply {
            text = sharedUrl
            textSize = 12f
            setTextColor(0xFF94A3B8.toInt())
            maxLines = 2
            setPadding(0, 0, 0, 24)
        }
        root.addView(urlPreview)

        // Action 1: ULTRA DOWNLOAD ON VPS
        val btnUltra = Button(this).apply {
            text = "ULTRA DOWNLOAD ON VPS"
            setBackgroundColor(0xFF00F0FF.toInt())
            setTextColor(0xFF0A0D14.toInt())
            setOnClickListener { submitJob("SINGLE") }
        }
        root.addView(btnUltra)

        // Action 2: BURST DOWNLOAD ON FLEET
        val btnBurst = Button(this).apply {
            text = "BURST DOWNLOAD ON FLEET (Multi-Node)"
            setBackgroundColor(0xFF007A83.toInt())
            setTextColor(0xFFFFFFFF.toInt())
            setOnClickListener { submitJob("BURST") }
        }
        root.addView(btnBurst)

        // Action 3: Open through VPN
        val btnOpen = Button(this).apply {
            text = "Open in Browser through VPN"
            setBackgroundColor(0xFF1E293B.toInt())
            setTextColor(0xFFF0F4F8.toInt())
            setOnClickListener {
                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(sharedUrl)))
                finish()
            }
        }
        root.addView(btnOpen)

        // Action 4: Copy CyberShare link
        val btnCopy = Button(this).apply {
            text = "Copy Direct URL"
            setBackgroundColor(0xFF1E293B.toInt())
            setTextColor(0xFFF0F4F8.toInt())
            setOnClickListener {
                val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("URL", sharedUrl))
                Toast.makeText(this@ShareActivity, "URL copied to clipboard", Toast.LENGTH_SHORT).show()
                finish()
            }
        }
        root.addView(btnCopy)

        setContentView(root)
    }

    private fun submitJob(mode: String) {
        lifecycleScope.launch {
            Toast.makeText(this@ShareActivity, "Submitting $mode transfer to CyberFleet...", Toast.LENGTH_SHORT).show()
            val result = client.submitTransferJob(sharedUrl, mode)
            result.onSuccess { jobId ->
                Toast.makeText(this@ShareActivity, "Job Started: $jobId! Downloading remotely on VPS.", Toast.LENGTH_LONG).show()
                finish()
            }.onFailure { err ->
                Toast.makeText(this@ShareActivity, "Error: ${err.message}", Toast.LENGTH_LONG).show()
            }
        }
    }
}
