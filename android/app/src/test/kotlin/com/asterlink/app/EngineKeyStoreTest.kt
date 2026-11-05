package com.asterlink.app

import android.util.Base64
import java.io.File
import java.io.IOException
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 36], manifest = Config.NONE, shadows = [HostAtomicFile::class])
class EngineKeyStoreTest {
    @get:Rule val temporary = TemporaryFolder()
    private val key = ByteArray(32) { it.toByte() }
    private fun encoded(value: ByteArray = key) = Base64.encodeToString(value, Base64.NO_WRAP)
    private fun privateFile(root: File, name: String) = File(root, "engine-key-private-v1/$name")
    private fun store(root: File) = EngineKeyStore(root) { throw AssertionError("Keystore must not be accessed") }

    @Test fun newInstallationAndRestartsUseOnlyPrivateFiles() {
        val root = temporary.newFolder()
        assertEquals(encoded(), store(root).load(encoded()))
        File(root, "gopeed.db").writeText("encrypted database fixture")
        repeat(4) {
            assertEquals(encoded(), store(root).load(encoded(ByteArray(32) { 99 })))
        }
        assertArrayEquals(key, privateFile(root, "primary.bin").readBytes())
        assertArrayEquals(key, privateFile(root, "copy.bin").readBytes())
        assertFalse(File(root, "engine.key").exists())
    }

    @Test fun legacyMigrationKeepsDatabaseAndWrappedKeyAndNeverUnwrapsAgain() {
        val root = temporary.newFolder()
        val wrapped = File(root, "engine.key").apply { writeText("wrapped fixture") }
        val database = File(root, "gopeed.db").apply { writeText("encrypted database fixture") }
        var calls = 0
        val value = EngineKeyStore(root) {
            calls++
            assertEquals("wrapped fixture", it)
            encoded()
        }.load(encoded(ByteArray(32) { 99 }))
        assertEquals(encoded(), value)
        assertEquals(1, calls)
        repeat(4) { assertEquals(encoded(), store(root).load(value)) }
        assertEquals("wrapped fixture", wrapped.readText())
        assertEquals("encrypted database fixture", database.readText())
    }

    @Test fun damagedPrimaryRepairsFromTheCopyUsingCommittedIdentity() {
        for (damage in listOf("missing", "short", "long", "wrong")) {
            val root = temporary.newFolder()
            store(root).load(encoded())
            val primary = privateFile(root, "primary.bin")
            when (damage) {
                "missing" -> assertTrue(primary.delete())
                "short" -> primary.writeBytes(byteArrayOf(1, 2))
                "long" -> primary.writeBytes(ByteArray(1000))
                else -> primary.writeBytes(ByteArray(32) { 99 })
            }
            assertEquals(encoded(), store(root).load(encoded(ByteArray(32) { 88 })))
            assertArrayEquals(key, primary.readBytes())
            assertArrayEquals(key, privateFile(root, "copy.bin").readBytes())
        }
    }

    @Test fun aFailedRedundantRepairDoesNotDisableTheWorkingCopy() {
        val root = temporary.newFolder()
        store(root).load(encoded())
        val primary = privateFile(root, "primary.bin")
        assertTrue(primary.delete())
        assertTrue(primary.mkdir())
        File(primary, "occupied").writeText("prevent AtomicFile from replacing an empty directory")
        assertEquals(encoded(), store(root).load(encoded(ByteArray(32) { 99 })))
        repeat(3) { assertEquals(encoded(), store(root).load(encoded(ByteArray(32) { 99 }))) }
        assertArrayEquals(key, privateFile(root, "copy.bin").readBytes())
    }

    @Test fun authenticatedFlutterStateCanRecoverBothLostKeyFiles() {
        val root = temporary.newFolder()
        store(root).load(encoded())
        assertTrue(privateFile(root, "primary.bin").delete())
        assertTrue(privateFile(root, "copy.bin").delete())
        assertEquals(encoded(), store(root).load(encoded()))
        assertArrayEquals(key, privateFile(root, "primary.bin").readBytes())
        assertArrayEquals(key, privateFile(root, "copy.bin").readBytes())
    }

    @Test fun wrongFlutterKeyCannotReplaceLostPrivateKeysOrConsultKeystore() {
        val root = temporary.newFolder()
        store(root).load(encoded())
        val database = File(root, "gopeed.db").apply { writeText("encrypted database fixture") }
        val wrapped = File(root, "engine.key").apply { writeText("retired wrapped fixture") }
        val identity = privateFile(root, "identity.bin").readBytes()
        assertTrue(privateFile(root, "primary.bin").delete())
        assertTrue(privateFile(root, "copy.bin").delete())
        assertThrows(EngineKeyStore.Unavailable::class.java) {
            store(root).load(encoded(ByteArray(32) { 99 }))
        }
        assertArrayEquals(identity, privateFile(root, "identity.bin").readBytes())
        assertFalse(privateFile(root, "primary.bin").exists())
        assertFalse(privateFile(root, "copy.bin").exists())
        assertEquals("encrypted database fixture", database.readText())
        assertEquals("retired wrapped fixture", wrapped.readText())
    }

    @Test fun brokenOldKeystorePreservesOriginalDatabaseAndKey() {
        val root = temporary.newFolder()
        val wrapped = File(root, "engine.key").apply { writeText("wrapped fixture") }
        val database = File(root, "gopeed.db").apply { writeText("encrypted database fixture") }
        assertThrows(EngineKeyStore.Unavailable::class.java) {
            EngineKeyStore(root) { null }.load(encoded())
        }
        assertEquals("wrapped fixture", wrapped.readText())
        assertEquals("encrypted database fixture", database.readText())
        assertFalse(privateFile(root, "identity.bin").exists())
    }

    @Test fun missingOldKeyCannotGenerateANewOneForExistingDatabase() {
        val root = temporary.newFolder()
        val database = File(root, "gopeed.db").apply { writeText("encrypted database fixture") }
        assertThrows(EngineKeyStore.Unavailable::class.java) { store(root).load(encoded()) }
        assertEquals("encrypted database fixture", database.readText())
        assertFalse(privateFile(root, "primary.bin").exists())
    }

    @Test fun failedMigrationDoesNotPublishAnIdentityOrChangeOldData() {
        val root = temporary.newFolder()
        val wrapped = File(root, "engine.key").apply { writeText("wrapped fixture") }
        val database = File(root, "gopeed.db").apply { writeText("encrypted database fixture") }
        val blockedCopy = privateFile(root, "copy.bin")
        assertTrue(blockedCopy.mkdirs())
        val blocker = File(blockedCopy, "occupied").apply { writeText("prevent replacement") }
        assertThrows(IOException::class.java) {
            EngineKeyStore(root) { encoded() }.load(encoded(ByteArray(32) { 99 }))
        }
        assertFalse(privateFile(root, "identity.bin").exists())
        assertEquals("wrapped fixture", wrapped.readText())
        assertEquals("encrypted database fixture", database.readText())
        assertTrue(blocker.delete())
        assertTrue(blockedCopy.delete())
        assertEquals(encoded(), EngineKeyStore(root) { encoded() }.load(encoded()))
        assertEquals(encoded(), store(root).load(encoded()))
    }

    @Test fun interruptedIdentityPublicationFinishesWithoutKeystore() {
        val root = temporary.newFolder()
        store(root).load(encoded())
        assertTrue(privateFile(root, "identity.bin").delete())
        File(root, "engine.key").writeText("old wrapped fixture")
        File(root, "gopeed.db").writeText("encrypted database fixture")
        assertEquals(encoded(), store(root).load(encoded(ByteArray(32) { 99 })))
        assertEquals(32, privateFile(root, "identity.bin").length().toInt())
    }

    @Test fun damagedIdentityCannotFallBackToAnUnrelatedKey() {
        val root = temporary.newFolder()
        store(root).load(encoded())
        privateFile(root, "identity.bin").writeBytes(byteArrayOf(1))
        assertThrows(EngineKeyStore.Unavailable::class.java) { store(root).load(encoded()) }
        assertArrayEquals(key, privateFile(root, "primary.bin").readBytes())
    }

    @Test fun recoveryGenerationUsesSeparateStorageAndPreservesOldFiles() {
        val noBackup = temporary.newFolder()
        val original = EngineKeyStore.directory(noBackup, "").apply { mkdirs() }
        File(original, "engine.key").writeText("unreadable old key")
        File(original, "gopeed.db").writeText("encrypted database fixture")
        val fresh = EngineKeyStore.directory(noBackup, "a".repeat(32)).apply { mkdirs() }
        assertNotEquals(original, fresh)
        assertEquals(encoded(), store(fresh).load(encoded()))
        assertEquals("unreadable old key", File(original, "engine.key").readText())
        assertEquals("encrypted database fixture", File(original, "gopeed.db").readText())
        for (generation in listOf("../outside", "A".repeat(32), "a", "a".repeat(33))) {
            assertThrows(IllegalArgumentException::class.java) { EngineKeyStore.directory(noBackup, generation) }
        }
    }
}
