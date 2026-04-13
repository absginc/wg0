package io.wg0.android.storage

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKeys

/**
 * Encrypted SharedPreferences for storing JWT tokens, device secrets,
 * and enrollment state. Uses Android Jetpack Security's
 * EncryptedSharedPreferences with AES-256-GCM under a MasterKey
 * stored in the Android Keystore.
 *
 * Falls back to plain SharedPreferences on devices that don't
 * support the Keystore (very rare — API 23+ all support it).
 */
object SecureStorage {
    private const val FILE_NAME = "wg0_secure_prefs"

    private lateinit var prefs: SharedPreferences

    fun init(context: Context) {
        prefs = try {
            val masterKey = MasterKeys.getOrCreate(MasterKeys.AES256_GCM_SPEC)
            EncryptedSharedPreferences.create(
                FILE_NAME,
                masterKey,
                context,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
        } catch (_: Exception) {
            // Fallback for emulators / test builds.
            context.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)
        }
    }

    // MARK: Keys

    object Key {
        const val ACCESS_TOKEN = "wg0.access_token"
        const val ACCOUNT_EMAIL = "wg0.account_email"
        const val DEVICE_SECRET = "wg0.device_secret"
        const val NODE_ID = "wg0.node_id"
        const val WG_CONFIG = "wg0.wg_config"
        const val CONFIG_VERSION = "wg0.config_version"
        const val OVERLAY_IP = "wg0.overlay_ip"
        const val PUBLIC_KEY = "wg0.public_key"
    }

    // MARK: Read / Write / Delete

    fun save(key: String, value: String) {
        prefs.edit().putString(key, value).apply()
    }

    fun load(key: String): String? = prefs.getString(key, null)

    fun delete(key: String) {
        prefs.edit().remove(key).apply()
    }

    fun clearAll() {
        prefs.edit().clear().apply()
    }

    val isEnrolled: Boolean
        get() = load(Key.NODE_ID) != null && load(Key.DEVICE_SECRET) != null
}
