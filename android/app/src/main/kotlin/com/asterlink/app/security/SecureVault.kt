package com.asterlink.app.security

import android.content.Context
import android.util.Base64
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.SecretKey

data class StoredCredential(
    val label: String,
    val fields: Map<String, String>,
    val updatedAt: Long = System.currentTimeMillis()
)

/**
 * 凭据读写接口。把 [SecureVault] 的 Android 依赖（Keystore、SharedPreferences）
 * 与使用方隔离，使备份等纯逻辑可以在 JVM 单测里用内存实现替换。
 */
interface CredentialStore {
    fun putCredential(platformKey: String, credential: StoredCredential)
    fun getCredential(platformKey: String): StoredCredential?
    fun removeCredential(platformKey: String)
    fun putSecret(key: String, value: String)
    fun getSecret(key: String): String?
    fun removeSecret(key: String)

    /** 后台令牌刷新只能更新原账号，不能覆盖换号或退出登录产生的新状态。 */
    fun replaceCredential(platformKey: String, expected: StoredCredential?, replacement: StoredCredential): Boolean = synchronized(this) {
        if (getCredential(platformKey) != expected) false else {
            putCredential(platformKey, replacement)
            true
        }
    }
}

class SecureVault(context: Context) : CredentialStore {
    private val preferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val plain = context.getSharedPreferences("asterlink_plain_v2", Context.MODE_PRIVATE)

    @Synchronized
    override fun putCredential(platformKey: String, credential: StoredCredential) {
        val json = JSONObject().apply {
            put("label", credential.label)
            put("updatedAt", credential.updatedAt)
            put("fields", JSONObject(credential.fields))
        }.toString()
        plain.edit().putString("credential.$platformKey", json).remove("removed.credential.$platformKey").apply()
    }

    @Synchronized
    override fun getCredential(platformKey: String): StoredCredential? {
        val value = read("credential.$platformKey") ?: return null
        return runCatching {
            val json = JSONObject(value)
            val fieldsJson = json.getJSONObject("fields")
            val fields = fieldsJson.keys().asSequence().associateWith(fieldsJson::getString)
            StoredCredential(
                label = json.optString("label"),
                fields = fields,
                updatedAt = json.optLong("updatedAt")
            )
        }.getOrNull()
    }

    @Synchronized
    override fun removeCredential(platformKey: String) {
        plain.edit().remove("credential.$platformKey").putBoolean("removed.credential.$platformKey", true).apply()
    }

    @Synchronized
    override fun putSecret(key: String, value: String) {
        plain.edit().putString("secret.$key", value).remove("removed.secret.$key").apply()
    }

    @Synchronized
    override fun getSecret(key: String): String? = read("secret.$key")

    @Synchronized
    override fun removeSecret(key: String) {
        plain.edit().remove("secret.$key").putBoolean("removed.secret.$key", true).apply()
    }

    fun seal(value: String): String = "plain-v2:$value"

    fun open(value: String): String? = if (value.startsWith("plain-v2:")) value.removePrefix("plain-v2:")
        else runCatching { decrypt(value) }.getOrNull()

    private fun read(name: String): String? {
        if (plain.getBoolean("removed.$name", false)) return null
        if (plain.contains(name)) return plain.getString(name, null)
        // Older native records remain available for a one-time read. Preserve
        // ciphertext when the old key is unavailable; never generate a new key.
        val value = preferences.getString(name, null)?.let(::open) ?: return null
        plain.edit().putString(name, value).apply()
        return value
    }

    private fun decrypt(value: String): String {
        val packed = Base64.decode(value, Base64.NO_WRAP)
        return AesGcmBox.open(secretKey(), packed).toString(Charsets.UTF_8)
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        return keyStore.getKey(KEY_ALIAS, null) as? SecretKey
            ?: error("Legacy credential key is unavailable")
    }

    private companion object {
        const val PREFS_NAME = "asterlink_secure_v1"
        const val KEY_ALIAS = "com.asterlink.app.secure.v1"
    }
}
