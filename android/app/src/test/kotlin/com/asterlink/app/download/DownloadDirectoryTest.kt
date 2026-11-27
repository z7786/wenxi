package com.asterlink.app.download

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import com.asterlink.app.HostAtomicFile
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowContentResolver

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE, shadows = [HostAtomicFile::class])
class DownloadDirectoryTest {
    private lateinit var context: Context
    private lateinit var root: File
    private lateinit var selected: File
    private lateinit var tree: Uri
    private lateinit var provider: LocalDocuments
    private var granted = true

    @Before fun setup() {
        context = object : ContextWrapper(RuntimeEnvironment.getApplication()) {
            override fun checkUriPermission(uri: Uri, pid: Int, uid: Int, modeFlags: Int): Int =
                if (granted) PackageManager.PERMISSION_GRANTED else PackageManager.PERMISSION_DENIED
        }
        root = Environment.getExternalStorageDirectory().canonicalFile.apply { mkdirs() }
        selected = File(root, "Download/selected")
        tree = DocumentsContract.buildTreeDocumentUri("com.android.externalstorage.documents", "primary:Download/selected")
        provider = LocalDocuments(root).also {
            it.attachInfo(context, ProviderInfo().apply { authority = tree.authority })
            ShadowContentResolver.registerProviderInternal(tree.authority!!, it)
        }
    }

    @Test fun missingSelectedRootAndParentsAreRecreatedAtTheSameLocation() {
        assertFalse(selected.exists())
        val directory = DownloadDirectory(context).open(tree)
        assertTrue(selected.isDirectory)
        assertTrue(directory.isDirectory)
        assertEquals(tree, DocumentsContract.buildTreeDocumentUri(directory.uri.authority, DocumentsContract.getTreeDocumentId(directory.uri)))
        // A second download must recover even after the cleaner runs again.
        assertTrue(selected.delete())
        assertTrue(DownloadDirectory(context).open(tree).isDirectory)
        assertTrue(selected.isDirectory)
    }

    @Test fun deniedPermissionDoesNotCreateDirectoriesAndCanRetryAfterReauthorization() {
        granted = false
        val error = assertThrows(IOException::class.java) { DownloadDirectory(context).open(tree) }
        assertTrue(error.message!!.contains("授权"))
        assertFalse(selected.exists())
        granted = true
        assertTrue(DownloadDirectory(context).open(tree).isDirectory)
    }

    @Test fun occupiedPathIsNotReplacedOrRedirected() {
        selected.parentFile!!.mkdirs()
        selected.writeText("keep")
        assertThrows(IOException::class.java) { DownloadDirectory(context).open(tree) }
        assertEquals("keep", selected.readText())
    }

    @Test fun parentGrantRecoversDeletedSelectionEvenWhenItsOwnGrantIsRevoked() {
        granted = false
        provider.revokedTree = "primary:Download/selected"
        selected.parentFile!!.mkdirs()
        val parent = DocumentsContract.buildTreeDocumentUri(tree.authority, "primary:Download")
        context.contentResolver.takePersistableUriPermission(parent,
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        val directory = DownloadDirectory(context).open(tree)
        assertTrue(selected.isDirectory)
        assertEquals("primary:Download", DocumentsContract.getTreeDocumentId(directory.uri))
        assertEquals("primary:Download/selected", DocumentsContract.getDocumentId(directory.uri))
        assertEquals(directory.uri, DownloadDirectory(context).open(tree).uri)
        assertTrue(selected.delete())
        assertEquals(directory.uri, DownloadDirectory(context).open(tree).uri)
        val source = File(context.cacheDir, "parent-source.bin").apply { writeText("saved") }
        val saved = DownloadFileSaver(context).save(source, "parent.bin", "", tree.toString())
        assertEquals("saved", provider.file(Uri.parse(saved)).readText())
    }

    @Test fun opaqueOrOutsideVolumeIdsNeverBecomeLocalDirectories() {
        for (uri in listOf(
            DocumentsContract.buildTreeDocumentUri("other.documents", "primary:Download/selected"),
            DocumentsContract.buildTreeDocumentUri(tree.authority, "primary:../escape"),
            DocumentsContract.buildTreeDocumentUri(tree.authority, "primary:Download/../escape"),
            DocumentsContract.buildTreeDocumentUri(tree.authority, "missing-volume:Download/selected"),
        )) {
            assertThrows(IOException::class.java) { DownloadDirectory(context).open(uri) }
        }
        assertFalse(selected.exists())
    }

    @Test fun bothDownloadWritersUseDirectoryRecovery() {
        val source = File(context.cacheDir, "source.bin").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        val saved = DownloadFileSaver(context).save(source, "legacy.bin", "", tree.toString())
        assertArrayEquals(source.readBytes(), provider.file(Uri.parse(saved)).readBytes())
        assertTrue(File(selected, "legacy.bin").delete())
        assertTrue(selected.delete())
        val store = DownloadTargetStore(
            context,
            descriptorPath = { File(selected, "direct.bin").absolutePath },
        )
        try {
            val target = store.open("new-task", "direct.bin", "", tree.toString())
            assertTrue(selected.isDirectory)
            assertEquals(tree.toString(), target["destination"])
            assertTrue(File(selected, "direct.bin").isFile)
        } finally { store.close() }
    }

    class LocalDocuments(private val root: File) : ContentProvider() {
        var revokedTree: String? = null
        override fun onCreate() = true
        fun file(uri: Uri): File {
            if (DocumentsContract.getTreeDocumentId(uri) == revokedTree) throw SecurityException("grant revoked")
            val id = DocumentsContract.getDocumentId(uri)
            if (!id.startsWith("primary:")) throw FileNotFoundException("volume missing")
            val file = File(root, id.removePrefix("primary:"))
            if (!file.canonicalPath.startsWith(root.path + File.separator)) throw FileNotFoundException("outside root")
            return file
        }
        override fun getType(uri: Uri): String? = file(uri).takeIf { it.exists() }?.let {
            if (it.isDirectory) DocumentsContract.Document.MIME_TYPE_DIR else "application/octet-stream"
        }
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
            val target = file(uri)
            val columns = projection ?: arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE)
            return MatrixCursor(columns).apply {
                val entries = if (uri.lastPathSegment == "children") target.listFiles().orEmpty().toList()
                    else if (target.exists()) listOf(target) else emptyList()
                for (entry in entries) addRow(columns.map { column -> when (column) {
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID -> "primary:" + entry.relativeTo(root).invariantSeparatorsPath
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME -> entry.name
                    DocumentsContract.Document.COLUMN_MIME_TYPE -> if (entry.isDirectory) DocumentsContract.Document.MIME_TYPE_DIR else "application/octet-stream"
                    else -> 0
                } }.toTypedArray())
            }
        }
        override fun call(method: String, arg: String?, extras: android.os.Bundle?): android.os.Bundle? {
            if (method != "android:createDocument") return super.call(method, arg, extras)
            val parent = extras!!.getParcelable<Uri>("uri")!!
            val name = extras.getString("_display_name")!!
            val target = File(file(parent), name)
            if (!target.parentFile!!.isDirectory) throw FileNotFoundException("parent removed")
            if (extras.getString("mime_type") == DocumentsContract.Document.MIME_TYPE_DIR) check(target.mkdir())
            else check(target.createNewFile())
            return android.os.Bundle().apply {
                putParcelable("uri", DocumentsContract.buildDocumentUriUsingTree(parent,
                    "primary:" + target.relativeTo(root).invariantSeparatorsPath))
            }
        }
        override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor =
            ParcelFileDescriptor.open(file(uri), ParcelFileDescriptor.parseMode(mode))
        override fun insert(uri: Uri, values: ContentValues?): Uri? = null
        override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = if (file(uri).delete()) 1 else 0
    }
}
