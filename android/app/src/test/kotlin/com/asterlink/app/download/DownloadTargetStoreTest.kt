package com.asterlink.app.download

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ProviderInfo
import android.content.pm.ResolveInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import android.provider.MediaStore
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructStat
import android.util.AtomicFile
import com.asterlink.app.HostAtomicFile
import java.io.File
import java.io.FileDescriptor
import java.io.FileNotFoundException
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.util.IdentityHashMap
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadows.ShadowContentResolver

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE, shadows = [HostAtomicFile::class])
class DownloadTargetStoreTest {
    private lateinit var context: Context
    private lateinit var provider: Downloads
    private lateinit var root: File
    private lateinit var journals: File
    private val stores = mutableListOf<DownloadTargetStore>()
    private var syncs = 0

    @Before fun setup() {
        context = RuntimeEnvironment.getApplication()
        root = File(context.filesDir, "direct-download-test").apply { mkdirs() }
        journals = File(root, "journals")
        provider = Downloads(File(root, "destination").apply { mkdirs() }).also {
            it.attachInfo(context, ProviderInfo().apply { authority = "media" })
            ShadowContentResolver.registerProviderInternal("media", it)
        }
    }

    @After fun cleanup() {
        stores.forEach { it.close() }
        GrantedDescriptorOs.clear()
    }

    private fun store(
        probe: (ParcelFileDescriptor) -> String = { provider.lastOpened!!.absolutePath },
        writer: (AtomicFile, ByteArray) -> Unit = ::writeAtomic,
    ) = DownloadTargetStore(context, journals, probe, { syncs++ }, writer).also(stores::add)

    private fun open(store: DownloadTargetStore, id: String = "task", name: String = "video.mp4", destination: String? = null) =
        store.open(id, name, "movies", destination)

    private fun value(target: Map<String, Any?>, key: String) = target[key] as String

    private fun write(target: Map<String, Any?>, bytes: ByteArray) {
        RandomAccessFile(value(target, "path"), "rw").use {
            it.write(bytes)
            it.fd.sync()
        }
    }

    private fun release(store: DownloadTargetStore, target: Map<String, Any?>, id: String = "task") =
        store.release(id, value(target, "lease"))

    @Test
    @Config(shadows = [GrantedDescriptorOs::class])
    fun grantedDescriptorWorksWithoutReopeningItsLocator() {
        provider.onDescriptorOpened = GrantedDescriptorOs::attach
        val store = DownloadTargetStore(context, journals).also(stores::add)
        val target = open(store)
        val lease = value(target, "lease")
        val file = provider.rows.getValue(value(target, "uri")).file
        // Robolectric's descriptor number is not a filesystem path on this
        // host. The real probe and I/O bridge must only use its granted FD.
        assertTrue(value(target, "path").startsWith("/proc/self/fd/"))
        assertFalse(File(value(target, "path")).exists())
        assertEquals(4, store.access("task", lease, "write", offset = 2, data = byteArrayOf(3, 4, 5, 6)))
        assertEquals(2, store.access("task", lease, "write", offset = 0, data = byteArrayOf(1, 2)))
        assertEquals(6L, store.access("task", lease, "length"))
        assertArrayEquals(byteArrayOf(2, 3, 4), store.access("task", lease, "read", offset = 1, length = 3) as ByteArray)
        store.access("task", lease, "truncate", length = 4)
        store.access("task", lease, "flush")
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), file.readBytes())
        release(store, target)
        assertThrows(IOException::class.java) { store.access("task", lease, "read", length = 4) }
        val resumed = open(store)
        val nextLease = value(resumed, "lease")
        assertNotEquals(lease, nextLease)
        assertEquals(4L, store.access("task", nextLease, "length"))
        assertThrows(IOException::class.java) { store.access("task", lease, "truncate", length = 0) }
        store.finish("task", nextLease, "video.mp4")
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), store.access("task", nextLease, "read", length = 4) as ByteArray)
        assertThrows(IOException::class.java) { store.access("task", nextLease, "write", data = byteArrayOf(9)) }
        assertThrows(IOException::class.java) { store.access("task", nextLease, "truncate", length = 0) }
        store.forget("task")
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), file.readBytes())
    }

    @Test fun descriptorIoRejectsInvalidRangesAndForeignLeasesBeforeAccess() {
        val store = store()
        val target = open(store)
        val other = open(store, id = "other")
        val lease = value(target, "lease")
        assertThrows(IOException::class.java) { store.access("task", value(other, "lease"), "truncate", length = 0) }
        assertThrows(IllegalArgumentException::class.java) { store.access("task", lease, "read", length = 1024 * 1024 + 1L) }
        assertThrows(IllegalArgumentException::class.java) { store.access("task", lease, "read", offset = -1, length = 1) }
        assertThrows(IllegalArgumentException::class.java) { store.access("task", lease, "read", offset = Long.MAX_VALUE, length = 1) }
        assertThrows(IllegalArgumentException::class.java) { store.access("task", lease, "write", offset = -1, data = byteArrayOf(1)) }
        assertThrows(IllegalArgumentException::class.java) { store.access("task", lease, "write", data = ByteArray(1024 * 1024 + 1)) }
        assertThrows(IllegalArgumentException::class.java) { store.access("task", lease, "write") }
        assertThrows(IllegalArgumentException::class.java) { store.access("task", lease, "truncate", length = -1) }
        assertThrows(IllegalArgumentException::class.java) { store.access("task", lease, "unknown") }
        assertEquals(0L, provider.rows.getValue(value(target, "uri")).file.length())
        store.validateBinding("task", value(target, "path"), value(target, "key"))
    }

    @Test fun targetBytesAreWrittenInPlaceAndOnlyFinishPublishes() {
        val store = store()
        assertNull(store.inspect("task"))
        val target = open(store)
        val uri = value(target, "uri")
        val row = provider.rows.getValue(uri)
        assertTrue(row.pending)
        assertEquals("Download/movies", row.path)
        assertEquals(listOf("rw"), provider.modes)
        val bytes = byteArrayOf(5, 4, 3, 2, 1)
        write(target, bytes)
        assertArrayEquals(bytes, row.file.readBytes())
        assertFalse(store.inspect("task")!!["published"] as Boolean)
        assertFalse(store.inspect("task")!!["publishing"] as Boolean)
        assertEquals(uri, store.finish("task", value(target, "lease"), "video.mp4"))
        assertEquals(1, syncs)
        assertFalse(row.pending)
        assertTrue(store.inspect("task")!!["published"] as Boolean)
        assertFalse(store.inspect("task")!!["publishing"] as Boolean)
        store.forget("task")
        assertNull(store.inspect("task"))
        assertArrayEquals(bytes, row.file.readBytes())
        assertEquals(0, provider.deletions)
    }

    @Test fun reopenAfterProcessRestartPreservesUriKeyAndBytesWithoutTruncating() {
        val first = store()
        val before = open(first)
        write(before, byteArrayOf(10, 20, 30))
        first.close()
        val second = store()
        val after = open(second)
        assertEquals(before["uri"], after["uri"])
        assertEquals(before["key"], after["key"])
        assertNotEquals(before["lease"], after["lease"])
        assertArrayEquals(byteArrayOf(10, 20, 30), File(value(after, "path")).readBytes())
        RandomAccessFile(value(after, "path"), "rw").use { it.seek(3); it.write(40) }
        assertArrayEquals(byteArrayOf(10, 20, 30, 40), provider.rows.getValue(value(after, "uri")).file.readBytes())
        assertEquals(1, provider.insertions)
        assertTrue(provider.modes.all { it == "rw" || it == "r" })
    }

    @Test fun publishedJournalRecoversWithoutOpeningOrWritingTheFileAgain() {
        val first = store()
        val target = open(first)
        val bytes = byteArrayOf(11, 22, 33)
        write(target, bytes)
        first.finish("task", value(target, "lease"), "video.mp4")
        first.close()
        val second = store()
        val recovered = second.inspect("task")!!
        assertEquals(target["uri"], recovered["uri"])
        assertTrue(recovered["published"] as Boolean)
        assertFalse(recovered.containsKey("path"))
        assertFalse(recovered.containsKey("lease"))
        val opens = provider.modes.size
        provider.denied = true
        assertEquals(target["uri"], second.finish("task", value(target, "lease"), "video.mp4"))
        assertThrows(IOException::class.java) { second.discard("task") }
        second.forget("task")
        assertNull(second.inspect("task"))
        assertEquals(opens, provider.modes.size)
        assertEquals(1, syncs)
        assertArrayEquals(bytes, provider.rows.getValue(value(target, "uri")).file.readBytes())
    }

    @Test fun repeatedOpenIsIdempotentAndLocationChangesCannotLoseProgress() {
        val store = store()
        val target = open(store)
        write(target, byteArrayOf(8, 9))
        assertEquals(target, open(store))
        assertThrows(IOException::class.java) { store.open("task", "video.mp4", "other", null) }
        assertThrows(IOException::class.java) { open(store, destination = "content://documents/tree/elsewhere") }
        assertThrows(IOException::class.java) { open(store, name = "different.mp4") }
        assertArrayEquals(byteArrayOf(8, 9), File(value(target, "path")).readBytes())
        assertEquals(1, provider.insertions)
    }

    @Test fun lateAndCrossTaskLeasesCannotCloseOrPublishAnotherRun() {
        val store = store()
        val original = open(store)
        val other = open(store, id = "other")
        assertThrows(IOException::class.java) { store.finish("task", value(other, "lease"), "video.mp4") }
        assertThrows(IOException::class.java) { store.validateBinding("task", value(other, "path"), value(other, "key")) }
        store.release("task", value(other, "lease"))
        store.validateBinding("task", value(original, "path"), value(original, "key"))
        release(store, original)
        val renewed = open(store)
        assertNotEquals(original["lease"], renewed["lease"])
        release(store, original)
        store.validateBinding("task", value(renewed, "path"), value(renewed, "key"))
        assertThrows(IOException::class.java) { store.validateBinding("task", "/tmp/unrelated", value(renewed, "key")) }
        assertThrows(IOException::class.java) { store.finish("task", value(original, "lease"), "video.mp4") }
        assertTrue(provider.rows.getValue(value(renewed, "uri")).pending)
    }

    @Test fun cancellationDeletesOnlyItsOwnedUnfinishedTarget() {
        val store = store()
        val first = open(store)
        val second = open(store, id = "other")
        assertThrows(IOException::class.java) { store.forget("task") }
        assertThrows(IllegalArgumentException::class.java) { store.discard("../other") }
        store.discard("task")
        store.discard("task")
        assertNull(store.inspect("task"))
        assertFalse(provider.rows.containsKey(value(first, "uri")))
        assertTrue(provider.rows.containsKey(value(second, "uri")))
        assertEquals(1, provider.deletions)
        store.finish("other", value(second, "lease"), "video.mp4")
        assertThrows(IOException::class.java) { store.discard("other") }
        assertTrue(provider.rows.containsKey(value(second, "uri")))
    }

    @Test fun copiedJournalCannotDeleteADifferentTaskTarget() {
        val store = store()
        val first = open(store)
        File(journals, "other.json").writeBytes(File(journals, "task.json").readBytes())
        assertThrows(IOException::class.java) { store.discard("other") }
        assertThrows(IOException::class.java) { store.inspect("other") }
        assertTrue(provider.rows.containsKey(value(first, "uri")))
        assertEquals(0, provider.deletions)
    }

    @Test fun journalCreationFailureRollsBackTheNewProviderFile() {
        val store = store(writer = { _, _ -> throw IOException("fixture journal disk full") })
        assertThrows(IOException::class.java) { open(store) }
        assertNull(store.inspect("task"))
        assertEquals(1, provider.insertions)
        assertEquals(1, provider.deletions)
        assertTrue(provider.rows.isEmpty())
    }

    @Test fun unsupportedRandomAccessRollsBackOnlyNewEmptyFiles() {
        val rejecting = store(probe = { throw IOException("ESPIPE") })
        val error = assertThrows(IOException::class.java) { open(rejecting) }
        assertTrue(error.message!!.contains("随机读写"))
        assertNull(rejecting.inspect("task"))
        assertTrue(provider.rows.isEmpty())

        val working = store()
        val target = open(working)
        write(target, byteArrayOf(1, 2, 3))
        working.close()
        assertThrows(IOException::class.java) { open(rejecting) }
        assertNotNull(rejecting.inspect("task"))
        assertArrayEquals(byteArrayOf(1, 2, 3), provider.rows.getValue(value(target, "uri")).file.readBytes())
    }

    @Test fun revokedPermissionAndMissingTargetNeverAllocateAReplacement() {
        val store = store()
        val target = open(store)
        write(target, byteArrayOf(6, 7))
        release(store, target)
        provider.denied = true
        assertThrows(IOException::class.java) { open(store) }
        assertThrows(SecurityException::class.java) { store.discard("task") }
        assertNotNull(store.inspect("task"))
        provider.denied = false
        val recovered = open(store)
        assertEquals(target["key"], recovered["key"])
        assertArrayEquals(byteArrayOf(6, 7), File(value(recovered, "path")).readBytes())
        release(store, recovered)
        provider.delete(Uri.parse(value(target, "uri")), null, null)
        val error = assertThrows(IOException::class.java) { open(store) }
        assertTrue(error.message!!.contains("已被删除"))
        assertNotNull(store.inspect("task"))
        assertEquals(1, provider.insertions)
        store.discard("task")
        assertNull(store.inspect("task"))
    }

    @Test fun missingFileBehindAnExistingUriIsNotRecreatedByReadWriteOpen() {
        val store = store()
        val target = open(store)
        write(target, byteArrayOf(7, 8, 9))
        release(store, target)
        val file = provider.rows.getValue(value(target, "uri")).file
        assertTrue(file.delete())
        val writeOpens = provider.modes.count { it == "rw" }
        assertThrows(IOException::class.java) { open(store) }
        assertFalse(file.exists())
        assertEquals(writeOpens, provider.modes.count { it == "rw" })
        assertNotNull(store.inspect("task"))
        assertEquals(1, provider.insertions)
    }

    @Test fun nullProviderDescriptorRollsBackANewTarget() {
        val store = store()
        provider.nullWriteDescriptor = true
        assertThrows(IOException::class.java) { open(store) }
        assertNull(store.inspect("task"))
        assertTrue(provider.rows.isEmpty())
    }

    @Test fun interruptedPublicationCannotBeDiscardedAndCanFinishAgain() {
        var writes = 0
        val store = store(writer = { file, bytes ->
            writes++
            if (writes == 3) throw IOException("fixture final journal failure")
            writeAtomic(file, bytes)
        })
        val target = open(store)
        write(target, byteArrayOf(1, 3, 5))
        assertThrows(IOException::class.java) { store.finish("task", value(target, "lease"), "video.mp4") }
        assertFalse(provider.rows.getValue(value(target, "uri")).pending)
        assertTrue(store.inspect("task")!!["publishing"] as Boolean)
        assertThrows(IOException::class.java) { store.discard("task") }
        assertThrows(IOException::class.java) { store.validateBinding("task", value(target, "path"), value(target, "key")) }
        store.close()
        val restarted = store()
        assertTrue(restarted.inspect("task")!!["publishing"] as Boolean)
        val resumed = open(restarted)
        assertEquals(target["uri"], resumed["uri"])
        assertThrows(IOException::class.java) { restarted.validateBinding("task", value(resumed, "path"), value(resumed, "key")) }
        assertEquals(target["uri"], restarted.finish("task", value(resumed, "lease"), "video.mp4"))
        restarted.forget("task")
        assertTrue(provider.rows.containsKey(value(target, "uri")))
        assertEquals(0, provider.deletions)
    }

    @Test fun providerPublishFailureRetainsTargetForRetry() {
        val store = store()
        val target = open(store)
        provider.failPublish = true
        assertThrows(IOException::class.java) { store.finish("task", value(target, "lease"), "video.mp4") }
        assertTrue(provider.rows.getValue(value(target, "uri")).pending)
        assertNotNull(store.inspect("task"))
        assertTrue(store.inspect("task")!!["publishing"] as Boolean)
        provider.failPublish = false
        store.finish("task", value(target, "lease"), "video.mp4")
        assertTrue(store.inspect("task")!!["published"] as Boolean)
    }

    @Test fun finalNameMustMatchTheNameChosenBeforeWriting() {
        val store = store()
        val target = open(store, name = "video.ts")
        assertThrows(IOException::class.java) { store.finish("task", value(target, "lease"), "video.mp4") }
        assertTrue(provider.rows.getValue(value(target, "uri")).pending)
        store.finish("task", value(target, "lease"), "video.ts")
    }

    @Test fun targetRemovedWhileDescriptorIsOpenCannotBecomeCompleted() {
        val store = store()
        val target = open(store)
        provider.rows.remove(value(target, "uri"))
        val error = assertThrows(IOException::class.java) { store.finish("task", value(target, "lease"), "video.mp4") }
        assertTrue(error.message!!.contains("已被删除"))
        assertFalse(store.inspect("task")!!["published"] as Boolean)
    }

    @Test fun mediaNamesAvoidOverwritingExistingFilesAndKeepRequestedNameStable() {
        val store = store()
        val first = open(store)
        write(first, byteArrayOf(9))
        val second = open(store, id = "other")
        assertEquals("video.mp4", second["name"])
        assertEquals("video (1).mp4", second["actualName"])
        write(second, byteArrayOf(8))
        assertArrayEquals(byteArrayOf(9), File(value(first, "path")).readBytes())
        store.finish("other", value(second, "lease"), "video.mp4")
    }

    @Test fun safCreatesTheFinalFileInsideSelectedSubdirectoriesAndReopensIt() {
        val directory = File(root, "saf").apply { mkdirs() }
        val (documents, destination) = documents(directory)
        val store = store(probe = { documents.lastOpened!!.absolutePath })
        val target = store.open("saf", "stream.ts", "series/episode", destination)
        val expected = File(directory, "series/episode/stream.ts")
        assertEquals(expected.absolutePath, target["path"])
        write(target, byteArrayOf(1, 4, 7))
        store.release("saf", value(target, "lease"))
        val resumed = store.open("saf", "stream.ts", "series/episode", destination)
        assertEquals(target["uri"], resumed["uri"])
        assertArrayEquals(byteArrayOf(1, 4, 7), expected.readBytes())
        store.finish("saf", value(resumed, "lease"), "stream.ts")
        store.forget("saf")
        assertTrue(expected.isFile)
        assertTrue(documents.modes.all { it == "rw" || it == "r" })
    }

    @Test fun safFinalJournalFailureRecoversPublicationWithoutDownloadingOrDeletingBytes() {
        val directory = File(root, "saf").apply { mkdirs() }
        val (documents, destination) = documents(directory)
        var writes = 0
        val first = store(probe = { documents.lastOpened!!.absolutePath }, writer = { file, bytes ->
            if (++writes == 3) throw IOException("fixture final journal failure")
            writeAtomic(file, bytes)
        })
        val target = first.open("saf", "stream.ts", "series", destination)
        val bytes = byteArrayOf(9, 6, 3)
        write(target, bytes)
        assertThrows(IOException::class.java) { first.finish("saf", value(target, "lease"), "stream.ts") }
        first.close()
        val second = store(probe = { documents.lastOpened!!.absolutePath })
        assertTrue(second.inspect("saf")!!["publishing"] as Boolean)
        assertThrows(IOException::class.java) { second.discard("saf") }
        val resumed = second.open("saf", "stream.ts", "series", destination)
        assertEquals(target["uri"], resumed["uri"])
        assertThrows(IOException::class.java) { second.validateBinding("saf", value(resumed, "path"), value(resumed, "key")) }
        second.finish("saf", value(resumed, "lease"), "stream.ts")
        second.forget("saf")
        assertArrayEquals(bytes, File(directory, "series/stream.ts").readBytes())
    }

    private fun documents(directory: File): Pair<StorageDocuments, String> {
        val documents = StorageDocuments(directory)
        val info = ProviderInfo().apply {
            authority = "direct.documents"
            name = StorageDocuments::class.java.name
            packageName = context.packageName
            applicationInfo = context.applicationInfo
            exported = true
            grantUriPermissions = true
            readPermission = "android.permission.MANAGE_DOCUMENTS"
            writePermission = readPermission
        }
        documents.attachInfo(context, info)
        ShadowContentResolver.registerProviderInternal(info.authority, documents)
        Shadows.shadowOf(context.packageManager).addResolveInfoForIntent(
            Intent(DocumentsContract.PROVIDER_INTERFACE), ResolveInfo().apply { providerInfo = info })
        val destination = DocumentsContract.buildTreeDocumentUri(info.authority, "root").toString()
        return documents to destination
    }

    private class Downloads(private val root: File) : ContentProvider() {
        data class Row(val file: File, val name: String, val path: String, var pending: Boolean)
        val rows = linkedMapOf<String, Row>()
        val modes = mutableListOf<String>()
        var insertions = 0
        var deletions = 0
        var denied = false
        var failPublish = false
        var nullWriteDescriptor = false
        var lastOpened: File? = null
        var onDescriptorOpened: ((ParcelFileDescriptor) -> Unit)? = null
        override fun onCreate() = true
        override fun getType(uri: Uri) = "application/octet-stream"
        override fun insert(uri: Uri, values: ContentValues?): Uri {
            if (denied) throw SecurityException("grant revoked")
            insertions++
            val name = values!!.getAsString(MediaStore.Downloads.DISPLAY_NAME)
            val result = Uri.parse("content://media/external/downloads/$insertions")
            val file = File(root, "$insertions-$name").apply { createNewFile() }
            rows[result.toString()] = Row(file, name, values.getAsString(MediaStore.Downloads.RELATIVE_PATH),
                values.getAsInteger(MediaStore.Downloads.IS_PENDING) == 1)
            return result
        }
        override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
            if (denied) throw SecurityException("grant revoked")
            modes += mode
            if (mode == "rw" && nullWriteDescriptor) return null
            val row = rows[uri.toString()] ?: throw FileNotFoundException("ENOENT")
            lastOpened = row.file
            return ParcelFileDescriptor.open(row.file, ParcelFileDescriptor.parseMode(mode)).also { onDescriptorOpened?.invoke(it) }
        }
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
            if (denied) throw SecurityException("grant revoked")
            return MatrixCursor(arrayOf(MediaStore.Downloads._ID, MediaStore.Downloads.DISPLAY_NAME)).apply {
                rows.entries.filter { entry ->
                    if (selectionArgs != null) entry.value.name == selectionArgs[0] && entry.value.path.trimEnd('/') == selectionArgs[1].trimEnd('/')
                    else entry.key == uri.toString()
                }.forEach { addRow(arrayOf(it.key.substringAfterLast('/'), it.value.name)) }
            }
        }
        override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int {
            if (denied) throw SecurityException("grant revoked")
            if (failPublish) return 0
            val row = rows[uri.toString()] ?: return 0
            row.pending = values!!.getAsInteger(MediaStore.Downloads.IS_PENDING) == 1
            return 1
        }
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int {
            if (denied) throw SecurityException("grant revoked")
            val row = rows.remove(uri.toString()) ?: return 0
            check(row.file.delete())
            deletions++
            return 1
        }
    }

    private class StorageDocuments(private val root: File) : DocumentsProvider() {
        var lastOpened: File? = null
        val modes = mutableListOf<String>()
        override fun onCreate() = true
        private fun file(id: String): File {
            require(id == "root" || id.startsWith("root/"))
            return if (id == "root") root else File(root, id.removePrefix("root/"))
        }
        override fun isChildDocument(parentDocumentId: String, documentId: String) = documentId.startsWith("$parentDocumentId/")
        override fun queryRoots(projection: Array<out String>?): Cursor = MatrixCursor(arrayOf(DocumentsContract.Root.COLUMN_ROOT_ID))
        override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
            val file = file(documentId)
            if (!file.exists()) throw FileNotFoundException("ENOENT")
            return MatrixCursor(arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE)).apply {
                addRow(arrayOf(documentId, file.name, if (file.isDirectory) DocumentsContract.Document.MIME_TYPE_DIR else "video/mp2t"))
            }
        }
        override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, sortOrder: String?): Cursor =
            MatrixCursor(arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID)).apply {
                file(parentDocumentId).listFiles()!!.forEach { addRow(arrayOf("$parentDocumentId/${it.name}")) }
            }
        override fun createDocument(parentDocumentId: String, mimeType: String, displayName: String): String {
            val id = "$parentDocumentId/$displayName"
            if (mimeType == DocumentsContract.Document.MIME_TYPE_DIR) check(file(id).mkdir()) else check(file(id).createNewFile())
            return id
        }
        override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
            modes += mode
            lastOpened = file(documentId)
            return ParcelFileDescriptor.open(lastOpened!!, ParcelFileDescriptor.parseMode(mode))
        }
        override fun deleteDocument(documentId: String) { check(file(documentId).delete()) }
    }

    /** Robolectric does not implement pwrite/ftruncate or a real fstat. Keep
     * those OS boundaries on the actual granted handle for this host test;
     * kernel permission denial and dup are separately exercised on Linux. */
    @Implements(Os::class)
    class GrantedDescriptorOs {
        private data class Streams(val input: FileInputStream, val output: FileOutputStream)

        companion object {
            private val files = IdentityHashMap<FileDescriptor, Streams>()

            fun attach(descriptor: ParcelFileDescriptor) {
                val fd = descriptor.fileDescriptor
                files[fd] = Streams(FileInputStream(fd), FileOutputStream(fd))
            }

            fun clear() { files.clear() }

            private fun streams(fd: FileDescriptor): Streams = files[fd]
                ?: throw ErrnoException("fixture descriptor", OsConstants.EBADF)

            @JvmStatic @Implementation
            fun fstat(fd: FileDescriptor): StructStat = StructStat(
                0L, 0L, OsConstants.S_IFREG, 1L, 0, 0, 0L,
                streams(fd).input.channel.size(), 0L, 0L, 0L, 4096L, 0L,
            )

            @JvmStatic @Implementation
            fun lseek(fd: FileDescriptor, offset: Long, whence: Int): Long {
                val channel = streams(fd).input.channel
                val base = when (whence) {
                    OsConstants.SEEK_SET -> 0L
                    OsConstants.SEEK_CUR -> channel.position()
                    OsConstants.SEEK_END -> channel.size()
                    else -> throw ErrnoException("lseek", OsConstants.EINVAL)
                }
                return channel.position(base + offset).position()
            }

            @JvmStatic @Implementation
            fun pread(fd: FileDescriptor, bytes: ByteArray, offset: Int, count: Int, position: Long): Int =
                streams(fd).input.channel.read(ByteBuffer.wrap(bytes, offset, count), position)

            @JvmStatic @Implementation
            fun pwrite(fd: FileDescriptor, bytes: ByteArray, offset: Int, count: Int, position: Long): Int =
                // Deliberate short writes exercise the bridge's completion loop.
                streams(fd).output.channel.write(ByteBuffer.wrap(bytes, offset, minOf(count, 2)), position)

            @JvmStatic @Implementation
            fun ftruncate(fd: FileDescriptor, length: Long) {
                val channel = streams(fd).output.channel
                if (length > channel.size()) channel.write(ByteBuffer.wrap(byteArrayOf(0)), length - 1)
                else channel.truncate(length)
            }

            @JvmStatic @Implementation
            fun fsync(fd: FileDescriptor) { streams(fd).output.channel.force(true) }
        }
    }

    companion object {
        private fun writeAtomic(file: AtomicFile, bytes: ByteArray) {
            val stream = file.startWrite()
            try { stream.write(bytes); file.finishWrite(stream) }
            catch (error: Throwable) { file.failWrite(stream); throw error }
        }
    }
}
