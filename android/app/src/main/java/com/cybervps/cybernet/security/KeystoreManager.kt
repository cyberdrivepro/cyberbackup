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
import java.math.BigInteger
import java.security.SecureRandom

object Curve25519 {
    private val P: BigInteger = BigInteger.valueOf(2).pow(255).subtract(BigInteger.valueOf(19))
    private val A24: BigInteger = BigInteger.valueOf(121665)

    fun computePublicKey(privateKey: ByteArray): ByteArray {
        val basePoint = ByteArray(32)
        basePoint[0] = 9
        return scalarMult(privateKey, basePoint)
    }

    fun scalarMult(scalar: ByteArray, uCoords: ByteArray): ByteArray {
        // RFC 7748 / WireGuard clamping
        val k = scalar.copyOf(32)
        k[0] = (k[0].toInt() and 248).toByte()
        k[31] = (k[31].toInt() and 127).toByte()
        k[31] = (k[31].toInt() or 64).toByte()

        val kInt = toBigIntegerLittleEndian(k)
        val x1 = toBigIntegerLittleEndian(uCoords).mod(P)

        var x2 = BigInteger.ONE
        var z2 = BigInteger.ZERO
        var x3 = x1
        var z3 = BigInteger.ONE
        var swap = 0

        for (t in 254 downTo 0) {
            val kt = if (kInt.testBit(t)) 1 else 0
            swap = swap xor kt
            if (swap != 0) {
                var tmp = x2; x2 = x3; x3 = tmp
                tmp = z2; z2 = z3; z3 = tmp
            }
            swap = kt

            val a = x2.add(z2).mod(P)
            val aa = a.multiply(a).mod(P)
            val b = x2.subtract(z2).mod(P)
            val bb = b.multiply(b).mod(P)
            val e = aa.subtract(bb).mod(P)
            val c = x3.add(z3).mod(P)
            val d = x3.subtract(z3).mod(P)
            val da = d.multiply(a).mod(P)
            val cb = c.multiply(b).mod(P)

            x3 = da.add(cb).mod(P).let { it.multiply(it).mod(P) }
            z3 = x1.multiply(da.subtract(cb).mod(P).let { it.multiply(it).mod(P) }).mod(P)
            x2 = aa.multiply(bb).mod(P)
            z2 = e.multiply(aa.add(A24.multiply(e).mod(P))).mod(P)
        }

        if (swap != 0) {
            var tmp = x2; x2 = x3; x3 = tmp
            tmp = z2; z2 = z3; z3 = tmp
        }

        val result = x2.multiply(z2.modPow(P.subtract(BigInteger.valueOf(2)), P)).mod(P)
        return toByteArrayLittleEndian(result, 32)
    }

    private fun toBigIntegerLittleEndian(bytes: ByteArray): BigInteger {
        val reversed = bytes.reversedArray()
        return BigInteger(1, reversed)
    }

    private fun toByteArrayLittleEndian(n: BigInteger, length: Int): ByteArray {
        val beBytes = n.toByteArray()
        val result = ByteArray(length)
        val start = if (beBytes.isNotEmpty() && beBytes[0] == 0.toByte()) 1 else 0
        val numBytes = beBytes.size - start
        for (i in 0 until numBytes) {
            result[i] = beBytes[beBytes.size - 1 - i]
        }
        return result
    }
}

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
     * Retrieves or generates a mathematically valid Curve25519 WireGuard key pair.
     * Derives the public key from the private key scalar via RFC 7748 scalar multiplication.
     */
    fun getOrCreateDeviceKeyPair(): Pair<String, String> {
        val storedPub = securePrefs.getString("device_public_key", null)
        val storedPriv = securePrefs.getString("device_private_key", null)

        if (storedPub != null && storedPriv != null) {
            return Pair(storedPub, storedPriv)
        }

        // Generate genuine RFC 7748 Curve25519 WireGuard keypair
        val random = SecureRandom()
        val privateBytes = ByteArray(32)
        random.nextBytes(privateBytes)
        val publicBytes = Curve25519.computePublicKey(privateBytes)

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
