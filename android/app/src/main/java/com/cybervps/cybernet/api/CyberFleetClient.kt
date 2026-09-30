package com.cybervps.cybernet.api

import com.cybervps.cybernet.model.*
import com.cybervps.cybernet.security.KeystoreManager
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit

class CyberFleetClient(private val keystore: KeystoreManager) {

    private val gson = Gson()
    private val jsonMediaType = "application/json; charset=utf-8".toMediaType()

    private val httpClient = OkHttpClient.Builder()
        .addInterceptor { chain ->
            val orig = chain.request()
            val token = keystore.getAuthToken()
            if (!token.isNullOrBlank() && orig.header("Authorization") == null) {
                val authed = orig.newBuilder()
                    .header("Authorization", "Bearer $token")
                    .build()
                chain.proceed(authed)
            } else {
                chain.proceed(orig)
            }
        }
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .writeTimeout(15, TimeUnit.SECONDS)
        .build()

    private fun getBaseUrl(): String = keystore.getControllerUrl().trimEnd('/')

    suspend fun enrollDevice(
        deviceName: String,
        osVersion: String,
        pairingToken: String? = null,
    ): Result<String> = withContext(Dispatchers.IO) {
        try {
            val (pubKey, _) = keystore.getOrCreateDeviceKeyPair()
            val payload = mutableMapOf(
                "name" to deviceName,
                "device_type" to "android",
                "os_version" to osVersion,
                "public_key" to pubKey,
            )
            if (!pairingToken.isNullOrBlank()) {
                payload["enrollment_token"] = pairingToken.trim()
            }
            val body = gson.toJson(payload).toRequestBody(jsonMediaType)
            val reqBuilder = Request.Builder()
                .url("${getBaseUrl()}/api/v1/net/devices/enroll")
                .post(body)
            if (!pairingToken.isNullOrBlank()) {
                reqBuilder.header("Authorization", "Bearer ${pairingToken.trim()}")
            }
            val request = reqBuilder.build()

            val response = httpClient.newCall(request).execute()
            if (!response.isSuccessful) {
                return@withContext Result.failure(IOException("Enrollment failed: HTTP ${response.code}"))
            }

            val respBody = response.body?.string() ?: ""
            val map: Map<String, Any> = gson.fromJson(respBody, object : TypeToken<Map<String, Any>>() {}.type)
            val deviceId = map["device_id"] as? String ?: ""
            val token = map["token"] as? String ?: ""

            keystore.saveAuthCredentials(deviceId, token, getBaseUrl())
            Result.success(deviceId)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getGateways(profile: ScoreProfile): Result<List<Gateway>> = withContext(Dispatchers.IO) {
        try {
            val request = Request.Builder()
                .url("${getBaseUrl()}/api/v1/net/gateways?profile=${profile.name}")
                .get()
                .build()

            val response = httpClient.newCall(request).execute()
            if (!response.isSuccessful) {
                return@withContext Result.failure(IOException("Gateways fetch failed: HTTP ${response.code}"))
            }

            val respBody = response.body?.string() ?: ""
            val map: Map<String, Any> = gson.fromJson(respBody, object : TypeToken<Map<String, Any>>() {}.type)
            val listJson = gson.toJson(map["gateways"])
            val gateways: List<Gateway> = gson.fromJson(listJson, object : TypeToken<List<Gateway>>() {}.type)
            Result.success(gateways)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun createSession(
        deviceId: String,
        protocol: String = "AUTO",
        profile: ScoreProfile = ScoreProfile.BALANCED,
        gatewayId: String? = null,
        dnsMode: DnsMode = DnsMode.CLOUDFLARE,
        customDns: String? = null,
        fullTunnel: Boolean = true
    ): Result<SessionResponse> = withContext(Dispatchers.IO) {
        try {
            val payload = mutableMapOf(
                "device_id" to deviceId,
                "protocol" to protocol,
                "score_profile" to profile.name,
                "dns_mode" to dnsMode.name,
                "full_tunnel" to fullTunnel
            )
            if (gatewayId != null) payload["gateway_id"] = gatewayId
            if (customDns != null) payload["custom_dns"] = customDns

            val body = gson.toJson(payload).toRequestBody(jsonMediaType)
            val request = Request.Builder()
                .url("${getBaseUrl()}/api/v1/net/session")
                .post(body)
                .build()

            val response = httpClient.newCall(request).execute()
            if (!response.isSuccessful) {
                return@withContext Result.failure(IOException("Session creation failed: HTTP ${response.code}"))
            }

            val respBody = response.body?.string() ?: ""
            val sessionResp = gson.fromJson(respBody, SessionResponse::class.java)
            Result.success(sessionResp)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun switchSession(sessionId: String, targetGatewayId: String): Result<Boolean> = withContext(Dispatchers.IO) {
        try {
            val payload = mapOf("session_id" to sessionId, "target_gateway_id" to targetGatewayId)
            val body = gson.toJson(payload).toRequestBody(jsonMediaType)
            val request = Request.Builder()
                .url("${getBaseUrl()}/api/v1/net/session/switch")
                .post(body)
                .build()

            val response = httpClient.newCall(request).execute()
            Result.success(response.isSuccessful)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun terminateSession(sessionId: String): Result<Boolean> = withContext(Dispatchers.IO) {
        try {
            val request = Request.Builder()
                .url("${getBaseUrl()}/api/v1/net/session/$sessionId")
                .delete()
                .build()
            val response = httpClient.newCall(request).execute()
            Result.success(response.isSuccessful)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun sendHeartbeat(sessionId: String, rxBytes: Long, txBytes: Long) = withContext(Dispatchers.IO) {
        try {
            val payload = mapOf("bytes_rx" to rxBytes, "bytes_tx" to txBytes)
            val body = gson.toJson(payload).toRequestBody(jsonMediaType)
            val request = Request.Builder()
                .url("${getBaseUrl()}/api/v1/net/session/$sessionId/heartbeat")
                .post(body)
                .build()
            httpClient.newCall(request).execute().close()
        } catch (_: Exception) {}
    }

    suspend fun submitTransferJob(url: String, mode: String): Result<String> = withContext(Dispatchers.IO) {
        try {
            val payload = mapOf("url" to url, "mode" to mode)
            val body = gson.toJson(payload).toRequestBody(jsonMediaType)
            val request = Request.Builder()
                .url("${getBaseUrl()}/api/v1/jobs")
                .post(body)
                .build()
            val response = httpClient.newCall(request).execute()
            if (!response.isSuccessful) return@withContext Result.failure(IOException("Job submission failed"))
            val map: Map<String, Any> = gson.fromJson(response.body?.string(), object : TypeToken<Map<String, Any>>() {}.type)
            val jobId = map["id"] as? String ?: (map["job"] as? Map<*, *>)?.get("id") as? String ?: ""
            Result.success(jobId)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}
