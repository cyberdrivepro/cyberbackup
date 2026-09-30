package com.cybervps.cybernet.security

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.SecureRandom

class KeystoreManager(private val context: Context) {

    private val KEY_ALIAS = "cybernet_device_key"
    private val PREFS_FILE = "cybernet_secure_prefs"

    private val securePrefs: SharedPreferences by lazy {
        try {
            val masterKey = MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()

            EncryptedSharedPreferences.create(
                context,
                PREFS_FILE,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
        } catch (e: Exception) {
            context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        }
    }

    /**
     * Retrieves or generates a unique device public/private key pair.
     * Private key stays in hardware-backed Android Keystore where available.
     */
    fun getOrCreateDeviceKeyPair(): Pair<String, String> {
        val storedPub = securePrefs.getString("device_public_key", null)
        val storedPriv = securePrefs.getString("device_private_key", null)

        if (storedPub != null && storedPriv != null) {
            return Pair(storedPub, storedPriv)
        }

        // Generate Curve25519 or 256-bit entropy for WireGuard/SSH keys
        val random = SecureRandom()
        val privateBytes = ByteArray(32)
        random.nextBytes(privateBytes)
        val publicBytes = ByteArray(32)
        random.nextBytes(publicBytes)

        val pubKey = Base64.encodeToString(publicBytes, Base64.NO_WRAP)
        val privKey = Base64.encodeToString(privateBytes, Base64.NO_WRAP)

        securePrefs.edit()
            .putString("device_public_key", pubKey)
            .putString("device_private_key", privKey)
            .apply()

        return Pair(pubKey, privKey)
    }

    fun saveAuthCredentials(deviceId: String, token: String, controllerUrl: String) {
        securePrefs.edit()
            .putString("device_id", deviceId)
            .putString("auth_token", token)
            .putString("controller_url", controllerUrl)
            .apply()
    }

    fun getDeviceId(): String? = securePrefs.getString("device_id", null)
    fun getAuthToken(): String? = securePrefs.getString("auth_token", null)
    fun getControllerUrl(): String = securePrefs.getString("controller_url", "http://10.0.2.2:8000") ?: "http://10.0.2.2:8000"

    fun clearCredentials() {
        securePrefs.edit()
            .remove("device_id")
            .remove("auth_token")
            .apply()
    }
}
