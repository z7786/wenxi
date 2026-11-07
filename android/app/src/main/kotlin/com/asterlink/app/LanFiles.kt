package com.asterlink.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.net.wifi.WifiManager
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import androidx.documentfile.provider.DocumentFile
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.net.URI
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** Keeps selected document URIs readable without copying large files to cache. */
class LanFiles(private val context: Context) {
    private val readers = ConcurrentHashMap<String, InputStream>()
    private var picker: MethodChannel.Result? = null
    private var multicast: WifiManager.MulticastLock? = null

    private fun localFile(location: String): File =
        if (Uri.parse(location).scheme == "file") File(URI(location)) else File(location)

    fun pick(activity: Activity?, result: MethodChannel.Result) {
        if (activity == null || picker != null) {
            result.error("lan", "请返回应用后重新选择文件", null)
            return
        }
        picker = result
        try {
            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                type = "*/*"
                addCategory(Intent.CATEGORY_OPENABLE)
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            }, PICK_FILES)
        } catch (_: Exception) {
            picker = null
            result.error("lan", "无法打开系统文件选择器", null)
        }
    }

    fun activityResult(request: Int, resultCode: Int, data: Intent?): Boolean {
        if (request != PICK_FILES) return false
        val pending = picker ?: return true
        picker = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            pending.success(emptyList<String>())
            return true
        }
        val uris = LinkedHashSet<Uri>()
        data.data?.let(uris::add)
        data.clipData?.let { clip ->
            for (i in 0 until minOf(clip.itemCount, MAX_FILES + 1)) uris.add(clip.getItemAt(i).uri)
        }
        if (uris.size > MAX_FILES) {
            pending.error("lan", "一次最多选择 10000 个文件", null)
            return true
        }
        for (uri in uris) {
            try { context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
            catch (_: Exception) { /* The temporary picker grant is still valid. */ }
        }
        pending.success(uris.map(Uri::toString))
        return true
    }

    fun stat(location: String): Map<String, Any> {
        val uri = Uri.parse(location)
        if (uri.scheme != "content") {
            val file = localFile(location)
            require(file.isAbsolute && file.isFile) { "所选文件不存在" }
            return mapOf("name" to file.name, "size" to file.length(), "modifiedAt" to file.lastModified())
        }
        var name = ""
        var size = -1L
        var modified = 0L
        val columns = arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE, DocumentsContract.Document.COLUMN_LAST_MODIFIED)
        val cursor = try { context.contentResolver.query(uri, columns, null, null, null) }
        catch (_: IllegalArgumentException) {
            context.contentResolver.query(uri, columns.take(2).toTypedArray(), null, null, null)
        }
        cursor?.use {
            if (it.moveToFirst()) {
                val n = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val s = it.getColumnIndex(OpenableColumns.SIZE)
                val m = it.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                if (n >= 0) name = it.getString(n).orEmpty()
                if (s >= 0 && !it.isNull(s)) size = it.getLong(s)
                if (m >= 0 && !it.isNull(m)) modified = it.getLong(m)
            }
        }
        if (size < 0) context.contentResolver.openFileDescriptor(uri, "r")?.use { size = it.statSize }
        require(name.isNotBlank() && size >= 0) { "文件提供器未返回有效文件信息，请换一个位置选择" }
        return mapOf("name" to name, "size" to size, "modifiedAt" to modified)
    }

    fun checkDirectory(location: String) {
        val uri = Uri.parse(location)
        val root = if (uri.scheme == "content") DocumentFile.fromTreeUri(context, uri)
            else DocumentFile.fromFile(localFile(location).canonicalFile)
        require(root != null && root.isDirectory && root.canRead()) { "所选文件夹不可读取，请重新选择" }
    }

    private data class UploadDocument(val id: String, val name: String, val mime: String,
        val size: Long, val modified: Long)

    private val uploadColumns = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_SIZE, DocumentsContract.Document.COLUMN_LAST_MODIFIED)

    private fun uploadDocument(cursor: Cursor): UploadDocument {
        fun text(column: String): String = cursor.getColumnIndex(column).let {
            if (it >= 0 && !cursor.isNull(it)) cursor.getString(it).orEmpty() else ""
        }
        fun number(column: String, fallback: Long): Long = cursor.getColumnIndex(column).let {
            if (it >= 0 && !cursor.isNull(it)) cursor.getLong(it) else fallback
        }
        val id = text(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
        val name = text(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
        val mime = text(DocumentsContract.Document.COLUMN_MIME_TYPE)
        require(id.isNotEmpty() && name.isNotBlank() && mime.isNotEmpty() &&
            name !in listOf(".", "..") && !name.contains('/') && !name.contains('\\')) {
            "文件提供器未返回有效的目录内容，请重新选择"
        }
        return UploadDocument(id, name, mime, number(DocumentsContract.Document.COLUMN_SIZE, -1),
            number(DocumentsContract.Document.COLUMN_LAST_MODIFIED, 0))
    }

    /** Query each SAF directory once, and fail instead of treating unreadable children as empty. */
    fun scanUploadDirectory(location: String): Map<String, Any> {
        val tree = Uri.parse(location)
        if (tree.scheme != "content") return scan(location, true, MAX_FILES)
        require(DocumentsContract.isTreeUri(tree)) { "请选择系统文件选择器中的文件夹" }
        val rootId = DocumentsContract.getTreeDocumentId(tree)
        val rootUri = DocumentsContract.buildDocumentUriUsingTree(tree, rootId)
        val root = requireNotNull(context.contentResolver.query(rootUri, uploadColumns, null, null, null)) {
            "所选文件夹不可读取，请重新选择"
        }.use { cursor ->
            require(cursor.moveToFirst()) { "所选文件夹已移走，请重新选择" }
            uploadDocument(cursor)
        }
        require(root.mime == DocumentsContract.Document.MIME_TYPE_DIR) { "请选择文件夹" }
        val pending = ArrayDeque<Pair<String, String>>()
        pending.add(rootId to "")
        val visited = hashSetOf(rootId)
        val directories = arrayListOf("")
        val files = ArrayList<Map<String, Any>>()
        while (pending.isNotEmpty()) {
            val (parentId, relative) = pending.removeFirst()
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
            requireNotNull(context.contentResolver.query(children, uploadColumns, null, null, null)) {
                "子目录不可读取，请检查文件夹权限后重新选择"
            }.use { cursor ->
                require(!cursor.extras.getBoolean(DocumentsContract.EXTRA_LOADING, false)) {
                    "文件提供器仍在加载目录，请稍后重新选择"
                }
                while (cursor.moveToNext()) {
                    val info = uploadDocument(cursor)
                    val path = if (relative.isEmpty()) info.name else "$relative/${info.name}"
                    require(path.split('/').size < 64) { "文件夹层级过深" }
                    if (info.mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        require(visited.add(info.id)) { "文件提供器返回了重复目录，请换一个位置选择" }
                        directories.add(path)
                        pending.add(info.id to path)
                    } else {
                        val fileUri = DocumentsContract.buildDocumentUriUsingTree(tree, info.id)
                        val size = if (info.size >= 0) info.size else
                            context.contentResolver.openFileDescriptor(fileUri, "r")?.use { it.statSize } ?: -1
                        require(size >= 0) { "文件提供器未返回有效文件大小，请换一个位置选择" }
                        files.add(mapOf("location" to fileUri.toString(), "relative" to path,
                            "size" to size, "modifiedAt" to info.modified))
                    }
                    require(files.size + directories.size <= MAX_FILES) {
                        "一次最多上传 10000 个文件和目录，请分批选择"
                    }
                }
            }
        }
        return mapOf("name" to root.name, "files" to files, "directories" to directories)
    }

    fun scan(location: String, folder: Boolean, maxEntries: Int? = null): Map<String, Any> {
        if (!folder) {
            val info = stat(location)
            return mapOf("name" to info.getValue("name"), "files" to listOf(
                info + mapOf("location" to location, "relative" to "")
            ), "directories" to emptyList<String>())
        }
        val uri = Uri.parse(location)
        val localRoot = if (uri.scheme == "content") null else localFile(location).canonicalFile
        val root = if (localRoot == null) DocumentFile.fromTreeUri(context, uri)
            else DocumentFile.fromFile(localRoot)
        require(root != null && root.isDirectory && root.canRead()) { "所选文件夹不可读取" }
        val files = ArrayList<Map<String, Any>>()
        val directories = arrayListOf("")
        var skippedLinks = 0
        val pending = ArrayDeque<Pair<DocumentFile, String>>()
        pending.add(root to "")
        while (pending.isNotEmpty()) {
            val (directory, relative) = pending.removeFirst()
            require(relative.count { it == '/' } < 63) { "文件夹层级过深" }
            for (child in directory.listFiles()) {
                val name = requireNotNull(child.name) { "无法读取文件名称" }
                require(name.isNotBlank() && !name.contains('/') && !name.contains('\\')) { "文件名称无效" }
                val path = if (relative.isEmpty()) name else "$relative/$name"
                val local = localRoot?.let { File(it, path.replace('/', File.separatorChar)) }
                if (local != null && local.canonicalFile != local.absoluteFile) { skippedLinks++; continue }
                val childLocation = local?.absolutePath ?: child.uri.toString()
                if (child.isDirectory) {
                    directories.add(path)
                    pending.add(child to path)
                } else if (child.isFile) {
                    files.add(stat(childLocation) + mapOf("location" to childLocation, "relative" to path))
                }
                require(files.size <= MAX_FILES && directories.size <= MAX_FILES) { "一次最多分享 10000 个文件或目录" }
                require(maxEntries == null || files.size + directories.size <= maxEntries) {
                    "一次最多上传 10000 个文件和目录，请分批选择"
                }
            }
        }
        return mapOf("name" to root.name.orEmpty(), "files" to files, "directories" to directories, "skippedLinks" to skippedLinks)
    }

    fun open(location: String, offset: Long): String {
        require(offset >= 0 && readers.size < 64) { "文件读取请求过多，请稍后重试" }
        val uri = Uri.parse(location)
        val stream = if (uri.scheme == "content") context.contentResolver.openInputStream(uri)
            else FileInputStream(localFile(location))
        requireNotNull(stream) { "所选文件不可读取" }
        try {
            if (offset > 0) {
                var positioned = false
                if (stream is FileInputStream) {
                    try { stream.channel.position(stream.channel.position() + offset); positioned = true }
                    catch (_: Exception) { }
                }
                if (!positioned) {
                    var left = offset
                    val discard = ByteArray(256 * 1024)
                    while (left > 0) {
                        val count = stream.read(discard, 0, minOf(left, discard.size.toLong()).toInt())
                        check(count > 0) { "文件长度发生变化" }
                        left -= count
                    }
                }
            }
            val id = UUID.randomUUID().toString()
            readers[id] = stream
            return id
        } catch (error: Throwable) { stream.close(); throw error }
    }

    fun read(id: String, length: Int): ByteArray {
        require(length in 1..512 * 1024)
        val stream = requireNotNull(readers[id]) { "文件读取已结束" }
        return synchronized(stream) {
            val bytes = ByteArray(length)
            val count = stream.read(bytes)
            if (count <= 0) ByteArray(0) else if (count == length) bytes else bytes.copyOf(count)
        }
    }

    fun close(id: String) { readers.remove(id)?.let { stream -> synchronized(stream) { stream.close() } } }

    fun createDirectories(destination: String, directories: List<String>) {
        require(directories.size <= MAX_FILES)
        val uri = Uri.parse(destination)
        val root = if (uri.scheme == "content") DocumentFile.fromTreeUri(context, uri)
            else DocumentFile.fromFile(localFile(destination).canonicalFile.apply { mkdirs() })
        require(root != null && root.isDirectory && root.canWrite()) { "保存目录不可写入" }
        for (path in directories) {
            val parts = path.split('/')
            require(parts.size <= 64 && parts.all { it.isNotBlank() && it !in listOf(".", "..") && !it.contains('\\') })
            var current: DocumentFile = root
            for (part in parts) {
                val existing = current.findFile(part)
                require(existing == null || existing.isDirectory) { "目标目录中有同名文件" }
                current = existing ?: requireNotNull(current.createDirectory(part)) { "无法创建接收目录" }
            }
        }
    }

    @Synchronized fun network(enabled: Boolean) {
        if (enabled) {
            if (multicast == null) {
                val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                multicast = wifi?.createMulticastLock("AsterLink:LanDiscovery")?.apply { setReferenceCounted(false); acquire() }
            }
        } else {
            multicast?.let { if (it.isHeld) it.release() }
            multicast = null
            readers.keys.toList().forEach { try { close(it) } catch (_: Exception) { } }
        }
    }

    companion object {
        private const val PICK_FILES = 838
        private const val MAX_FILES = 10000
    }
}
