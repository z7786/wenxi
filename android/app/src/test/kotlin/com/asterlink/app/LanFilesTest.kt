package com.asterlink.app

import android.content.ContentProvider
import android.content.ContentValues
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowContentResolver
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class LanFilesTest {
    private lateinit var root: File
    private lateinit var sample: File
    private lateinit var files: LanFiles
    private val payload = ByteArray(700_001) { (it * 31 % 251).toByte() }
    private val contentUri = Uri.parse("content://wenxi.lan.test/document/sample")

    private class DocumentProvider(private val source: File) : ContentProvider() {
        override fun onCreate() = true
        override fun getType(uri: Uri) = "application/octet-stream"
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
                           selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
            val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
            return MatrixCursor(columns).apply {
                addRow(columns.map {
                    when (it) {
                        OpenableColumns.DISPLAY_NAME -> source.name
                        OpenableColumns.SIZE -> source.length()
                        DocumentsContract.Document.COLUMN_LAST_MODIFIED -> source.lastModified()
                        else -> null
                    }
                }.toTypedArray<Any?>())
            }
        }
        override fun openFile(uri: Uri, mode: String) =
            ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY)
        override fun insert(uri: Uri, values: ContentValues?): Uri? = null
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
        override fun update(uri: Uri, values: ContentValues?, selection: String?,
                            selectionArgs: Array<out String>?) = 0
    }

    private class TreeProvider : ContentProvider() {
        val queries = arrayListOf<String>()
        var unreadable = false
        override fun onCreate() = true
        override fun getType(uri: Uri) = DocumentsContract.Document.MIME_TYPE_DIR
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
            selectionArgs: Array<out String>?, sortOrder: String?): Cursor? {
            queries.add(uri.toString())
            val id = DocumentsContract.getDocumentId(uri)
            val children = uri.lastPathSegment == "children"
            if (unreadable && id == "sub" && children) return null
            val directory = DocumentsContract.Document.MIME_TYPE_DIR
            val rows: List<Array<Any>> = if (!children) listOf(arrayOf(id, "资料", directory, 0L, 0L))
                else when (id) {
                    "root" -> listOf(arrayOf("sub", "子目录", directory, 0L, 0L),
                        arrayOf("empty", "空目录", directory, 0L, 0L),
                        arrayOf("one", "根文件.txt", "text/plain", 3L, 1234L))
                    "sub" -> listOf(arrayOf("two", "说明.txt", "text/plain", 5L, 5678L))
                    else -> emptyList()
                }
            return MatrixCursor(projection).apply { rows.forEach(::addRow) }
        }
        override fun insert(uri: Uri, values: ContentValues?): Uri? = null
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
        override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
    }

    @Before fun setup() {
        val app = RuntimeEnvironment.getApplication()
        root = File(app.cacheDir, "lan-files-test").apply { mkdirs() }
        sample = File(root, "手机样本.apk").apply { writeBytes(payload) }
        files = LanFiles(app)
        val provider = DocumentProvider(sample)
        provider.attachInfo(app, ProviderInfo().apply { authority = "wenxi.lan.test" })
        ShadowContentResolver.registerProviderInternal("wenxi.lan.test", provider)
    }

    @After fun cleanup() {
        files.network(false)
        root.deleteRecursively()
    }

    @Test fun documentUriCanBeReadAndResumedWithoutCopyingToCache() {
        val stat = files.stat(contentUri.toString())
        assertEquals("手机样本.apk", stat["name"])
        assertEquals(payload.size.toLong(), stat["size"])
        val before = root.listFiles()!!.map { it.name }.toSet()
        val handle = files.open(contentUri.toString(), 65_537)
        val first = files.read(handle, 512 * 1024)
        assertArrayEquals(payload.copyOfRange(65_537, 65_537 + first.size), first)
        val second = files.read(handle, 512 * 1024)
        assertArrayEquals(payload.copyOfRange(65_537 + first.size, payload.size), second)
        assertEquals(0, files.read(handle, 1).size)
        files.close(handle)
        assertEquals(before, root.listFiles()!!.map { it.name }.toSet())
        assertThrows(IllegalArgumentException::class.java) { files.read(handle, 1) }
    }

    @Test fun stoppingSharingClosesOpenReaders() {
        val one = files.open(sample.absolutePath, 0)
        val two = files.open(contentUri.toString(), 128)
        files.network(false)
        assertThrows(IllegalArgumentException::class.java) { files.read(one, 1) }
        assertThrows(IllegalArgumentException::class.java) { files.read(two, 1) }
        files.close(one) // Repeated release is harmless.
    }

    @Test fun directoryScanAndReceiveKeepNestedAndEmptyFolders() {
        val folder = File(root, "资料")
        File(folder, "空目录").mkdirs()
        File(folder, "子目录").mkdirs()
        File(folder, "子目录/说明.txt").writeText("hello")
        val selected = files.scan(folder.absolutePath, true)
        assertEquals("资料", selected["name"])
        assertEquals(setOf("", "空目录", "子目录"), (selected["directories"] as List<*>).toSet())
        val entries = selected["files"] as List<*>
        assertEquals(1, entries.size)
        assertEquals("子目录/说明.txt", (entries.single() as Map<*, *>)["relative"])
        val received = File(root, "接收")
        files.createDirectories(received.absolutePath, listOf("资料", "资料/空目录", "资料/子目录"))
        assertTrue(File(received, "资料/空目录").isDirectory)
        assertTrue(File(received, "资料/子目录").isDirectory)
        assertThrows(IllegalArgumentException::class.java) {
            files.createDirectories(received.absolutePath, listOf("../outside"))
        }
        assertFalse(File(root, "outside").exists())
    }

    @Test fun invalidOffsetsAndOversizedReadsAreRejected() {
        assertThrows(IllegalArgumentException::class.java) { files.open(sample.absolutePath, -1) }
        val handle = files.open(sample.absolutePath, 0)
        assertThrows(IllegalArgumentException::class.java) { files.read(handle, 512 * 1024 + 1) }
        assertThrows(IllegalArgumentException::class.java) { files.read(handle, 0) }
        files.close(handle)
    }

    @Test fun folderUploadScanIsReadOnlyAndCountsFilesAndDirectoriesTogether() {
        val folder = File(root, "上传资料").apply { mkdirs() }
        File(folder, "空目录").mkdirs()
        File(folder, "说明.txt").writeText("hello")
        files.checkDirectory(folder.absolutePath)
        val selected = files.scan(folder.absolutePath, true, 3)
        assertEquals("上传资料", selected["name"])
        assertEquals(setOf("", "空目录"), (selected["directories"] as List<*>).toSet())
        assertEquals(1, (selected["files"] as List<*>).size)
        assertThrows(IllegalArgumentException::class.java) { files.scan(folder.absolutePath, true, 2) }
        assertEquals("hello", File(folder, "说明.txt").readText())
        assertEquals(setOf("说明.txt", "空目录"), folder.listFiles()!!.map { it.name }.toSet())
        assertThrows(IllegalArgumentException::class.java) { files.checkDirectory(sample.absolutePath) }
    }

    @Test fun stoppingLanSharingDoesNotCloseASeparateUploadReader() {
        val uploader = LanFiles(RuntimeEnvironment.getApplication())
        val uploadReader = uploader.open(contentUri.toString(), 19)
        val lanReader = files.open(contentUri.toString(), 0)
        files.network(false)
        assertThrows(IllegalArgumentException::class.java) { files.read(lanReader, 1) }
        assertArrayEquals(payload.copyOfRange(19, 52), uploader.read(uploadReader, 33))
        uploader.close(uploadReader)
    }

    @Test fun uploadTreeQueriesEachDirectoryOnceAndRejectsUnreadableChildren() {
        val app = RuntimeEnvironment.getApplication()
        val provider = TreeProvider()
        provider.attachInfo(app, ProviderInfo().apply { authority = "wenxi.upload.tree" })
        ShadowContentResolver.registerProviderInternal("wenxi.upload.tree", provider)
        val tree = DocumentsContract.buildTreeDocumentUri("wenxi.upload.tree", "root")
        val selected = files.scanUploadDirectory(tree.toString())
        assertEquals("资料", selected["name"])
        assertEquals(setOf("", "子目录", "空目录"), (selected["directories"] as List<*>).toSet())
        val entries = selected["files"] as List<*>
        assertEquals(2, entries.size)
        assertEquals(setOf("根文件.txt", "子目录/说明.txt"), entries.map { (it as Map<*, *>)["relative"] }.toSet())
        assertEquals(4, provider.queries.size)
        assertTrue(entries.all { (it as Map<*, *>)["location"].toString().startsWith(tree.toString() + "/document/") })
        provider.unreadable = true
        assertThrows(IllegalArgumentException::class.java) { files.scanUploadDirectory(tree.toString()) }
    }
}
