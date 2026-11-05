package com.asterlink.app

import android.content.Context
import com.asterlink.app.security.SecureVault
import com.asterlink.app.security.StoredCredential
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 36], manifest = Config.NONE)
class SecureVaultPlainTest {
    private lateinit var context: Context
    @Before fun setup() {
        context = RuntimeEnvironment.getApplication()
        context.getSharedPreferences("asterlink_plain_v2", Context.MODE_PRIVATE).edit().clear().commit()
        context.getSharedPreferences("asterlink_secure_v1", Context.MODE_PRIVATE).edit().clear().commit()
    }

    @Test fun writesAndRestartsNeedNoKeystoreAndKeepExactCredentials() {
        val value = StoredCredential("fixture", mapOf("primary" to "cookie=fixture+%", "token" to "fixture-token"), 1234)
        val store = SecureVault(context)
        store.putCredential("Quark", value)
        store.putSecret("fixture", "plaintext+%")
        repeat(4) {
            assertEquals(value, SecureVault(context).getCredential("Quark"))
            assertEquals("plaintext+%", SecureVault(context).getSecret("fixture"))
        }
        val saved = context.getSharedPreferences("asterlink_plain_v2", Context.MODE_PRIVATE)
        assertTrue(saved.getString("credential.Quark", "")!!.contains("cookie=fixture+%"))
        assertEquals("plain-v2:headers+%", store.seal("headers+%"))
        assertEquals("headers+%", store.open(store.seal("headers+%")))
        assertTrue(context.getSharedPreferences("asterlink_secure_v1", Context.MODE_PRIVATE).all.isEmpty())
    }

    @Test fun deletedRecordsDoNotResurrectLegacyValuesAndNewLoginClearsTombstones() {
        val legacy = context.getSharedPreferences("asterlink_secure_v1", Context.MODE_PRIVATE)
        val value = """{"label":"old","updatedAt":1,"fields":{"primary":"cookie=old"}}"""
        legacy.edit().putString("credential.Quark", "plain-v2:$value")
            .putString("secret.old", "plain-v2:legacy-token").commit()
        val store = SecureVault(context)
        assertEquals("cookie=old", store.getCredential("Quark")!!.fields["primary"])
        assertEquals("legacy-token", store.getSecret("old"))
        store.removeCredential("Quark")
        store.removeSecret("old")
        assertNull(SecureVault(context).getCredential("Quark"))
        assertNull(SecureVault(context).getSecret("old"))
        assertEquals("plain-v2:$value", legacy.getString("credential.Quark", null))
        val replacement = StoredCredential("new", mapOf("primary" to "cookie=new"), 2)
        store.putCredential("Quark", replacement)
        store.putSecret("old", "new-token")
        assertEquals(replacement, SecureVault(context).getCredential("Quark"))
        assertEquals("new-token", SecureVault(context).getSecret("old"))
    }

    @Test fun unreadableLegacyCiphertextIsPreservedWithoutGeneratingAReplacementKey() {
        val legacy = context.getSharedPreferences("asterlink_secure_v1", Context.MODE_PRIVATE)
        legacy.edit().putString("credential.Quark", "unreadable-legacy-fixture").commit()
        assertNull(SecureVault(context).getCredential("Quark"))
        assertEquals("unreadable-legacy-fixture", legacy.getString("credential.Quark", null))
        assertFalse(context.getSharedPreferences("asterlink_plain_v2", Context.MODE_PRIVATE).contains("credential.Quark"))
    }
}
