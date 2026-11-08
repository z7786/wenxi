package com.asterlink.app.download

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.documentfile.provider.DocumentFile
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID

/** The URI is durable; the descriptor locator is valid only for its current lease. */
class DownloadTargetStore(
    private val context: Context,
    private val journalRoot: File = File(context.noBackupFilesDir, "download-targets"),
    private val descriptorPath: (ParcelFileDescriptor) -> String = ::seekablePath,
    private val syncDescriptor: (ParcelFileDescriptor) -> Unit = { Os.fsync(it.fileDescriptor) },
    private val writeJournal: (AtomicFile, ByteArray) -> Unit = ::writeAtomic,
) {
    private data class Target(
        val id: String,
        val key: String,
        val uri: String,
        val kind: String,
        val name: String,
        val actualName: String,
        val relativePath: String,
        val destination: String?,
        val published: Boolean = false,
        val publishing: Boolean = false,
    ) {
        fun json() = JSONObject().put("version", 1).put("id", id).put("key", key)
            .put("uri", uri).put("kind", kind).put("name", name).put("actualName", actualName)
            .put("relativePath", relativePath).put("destination", destination ?: JSONObject.NULL)
            .put("published", published).put("publishing", publishing)

        fun description(): Map<String, Any?> = mapOf(
            "exists" to true, "uri" to uri, "key" to key, "name" to name,
            "actualName" to actualName, "relativePath" to relativePath,
            "destination" to destination, "published" to published, "publishing" to publishing,
        )
    }

    private data class Lease(val descriptor: ParcelFileDescriptor, val path: String, val token: String, val key: String,
        var target: Target)
    private val leases = mutableMapOf<String, Lease>()
    private val saver = DownloadFileSaver(context)

    @Synchronized
    fun inspect(id: String): Map<String, Any?>? = read(id)?.description()

    @Synchronized
    fun open(id: String, name: String, relativePath: String, destination: String?): Map<String, Any?> {
        validateId(id)
        val requestedName = sanitize(name)
        val requestedPath = cleanPath(relativePath)
        val requestedDestination = destination?.trim()?.takeIf(String::isNotEmpty)
        var target = read(id)
        val created = target == null
        if (target != null) {
            if (target.name != requestedName || target.relativePath != requestedPath || target.destination != requestedDestination) {
                throw IOException("此任务已在原下载目录创建文件，请继续使用原目录，或删除任务后重新下载")
            }
        } else {
            check(journalRoot.mkdirs() || journalRoot.isDirectory) { "无法保存下载目标记录" }
            target = create(id, requestedName, requestedPath, requestedDestination)
            try {
                persist(target)
            } catch (error: Throwable) {
                try { saver.deleteOrThrow(target.uri) } catch (cleanup: Throwable) { error.addSuppressed(cleanup) }
                throw IOException("无法保存下载目标记录，创建已取消", error)
            }
        }
        val durable = target
        // "rw" may include O_CREAT in a DocumentsProvider or FileProvider. An
        // existing task must not silently recreate an externally deleted file.
        if (!created) requireAvailable(durable)
        leases[id]?.let { current ->
            check(current.key == durable.key) { "下载目标身份发生变化，请重新打开应用" }
            return opened(durable, current)
        }
        var descriptor: ParcelFileDescriptor? = null
        try {
            descriptor = try {
                context.contentResolver.openFileDescriptor(Uri.parse(durable.uri), "rw")
                    ?: throw IOException("目录提供方暂时无法打开下载文件，请稍后重试")
            } catch (error: FileNotFoundException) {
                if (saver.availability(durable.uri) == "missing") {
                    throw IOException("下载目标文件已被删除，请删除此任务后重新下载", error)
                }
                throw IOException("无法访问下载目标，请检查目录权限和存储设备后重试", error)
            }
            val path = try { descriptorPath(descriptor) } catch (error: Exception) {
                throw IOException("此目录不支持直接下载所需的随机读写，请选择本机或存储卡目录", error)
            }
            val lease = Lease(descriptor, path, UUID.randomUUID().toString(), durable.key, durable)
            leases[id] = lease
            descriptor = null
            return opened(durable, lease)
        } catch (error: Throwable) {
            descriptor?.close()
            // Only a newly created empty target is rolled back. Existing data always survives an open failure.
            if (created) {
                try {
                    saver.deleteOrThrow(durable.uri)
                    deleteJournal(id)
                } catch (cleanup: Throwable) { error.addSuppressed(cleanup) }
            }
            throw error
        }
    }

    private fun opened(target: Target, lease: Lease): Map<String, Any?> = target.description() + mapOf(
        "path" to lease.path, "lease" to lease.token,
    )

    /** Called at the JNI boundary; untrusted request paths never become arbitrary file writes. */
    @Synchronized
    fun validateBinding(id: String, path: String, key: String) {
        val target = read(id) ?: throw IOException("下载目标尚未打开")
        val lease = leases[id] ?: throw IOException("下载目标已关闭，请继续任务以重新打开")
        if (path != lease.path || key != lease.key || key != target.key || target.published || target.publishing) {
            throw IOException("下载目标凭据已失效，请重新继续任务")
        }
    }

    /** Positioned I/O uses the granted descriptor without reopening a filesystem path. */
    @Synchronized
    fun access(
        id: String, lease: String, operation: String, offset: Long = 0, length: Long = 0,
        data: ByteArray? = null,
    ): Any? {
        val target = leases[id]?.target ?: throw IOException("下载目标已关闭，请重新继续任务")
        val current = requireLease(id, lease, target)
        val fd = current.descriptor.fileDescriptor
        if (operation in setOf("write", "truncate")) {
            if (target.published || target.publishing) throw IOException("文件已进入完成处理，不能继续写入")
        }
        return when (operation) {
            "exists" -> when (saver.availability(target.uri)) {
                "present" -> true
                "missing" -> false
                else -> throw IOException("无法访问下载目标，请检查目录权限和存储设备后重试")
            }
            "length" -> Os.fstat(fd).st_size
            "read" -> {
                require(length in 0..MAX_IO_BYTES && offset >= 0 && offset <= Long.MAX_VALUE - length) { "无效的文件读取范围" }
                val buffer = ByteArray(length.toInt())
                val count = if (buffer.isEmpty()) 0 else Os.pread(fd, buffer, 0, buffer.size, offset)
                if (count <= 0) ByteArray(0) else buffer.copyOf(count)
            }
            "write" -> {
                val buffer = requireNotNull(data) { "缺少下载数据" }
                require(buffer.size <= MAX_IO_BYTES && offset >= 0 && offset <= Long.MAX_VALUE - buffer.size) { "无效的文件写入范围" }
                var written = 0
                while (written < buffer.size) {
                    val count = Os.pwrite(fd, buffer, written, buffer.size - written, offset + written)
                    if (count <= 0) throw IOException("下载文件未能完整写入，请检查存储空间")
                    written += count
                }
                written
            }
            "truncate" -> { require(length >= 0) { "无效的文件长度" }; Os.ftruncate(fd, length); null }
            "flush" -> { syncDescriptor(current.descriptor); null }
            else -> throw IllegalArgumentException("未知下载文件操作")
        }
    }

    /** Hash the granted descriptor locally. Only bounded positioned reads hold
     * the store lock; hashing and cancellation never keep other tasks waiting. */
    fun digest(id: String, lease: String, algorithm: String, checkpoint: () -> Unit = {}): String {
        val selected = when (algorithm.lowercase().replace("-", "")) {
            "md5" -> "MD5"
            "sha1" -> "SHA-1"
            "sha256" -> "SHA-256"
            else -> throw IllegalArgumentException("不支持的文件校验类型")
        }
        checkpoint()
        val (target, size) = synchronized(this) {
            val target = read(id) ?: throw IOException("下载目标记录不存在")
            val current = requireLease(id, lease, target)
            requireAvailable(target)
            target to Os.fstat(current.descriptor.fileDescriptor).st_size
        }
        val digest = MessageDigest.getInstance(selected)
        val buffer = ByteArray(256 * 1024)
        var offset = 0L
        while (offset < size) {
            checkpoint()
            val count = synchronized(this) {
                val current = requireLease(id, lease, target)
                Os.pread(current.descriptor.fileDescriptor, buffer, 0, minOf(buffer.size.toLong(), size - offset).toInt(), offset)
            }
            if (count <= 0) throw IOException("校验期间文件内容不完整，请重新下载")
            digest.update(buffer, 0, count)
            offset += count
        }
        checkpoint()
        synchronized(this) {
            val current = requireLease(id, lease, target)
            requireAvailable(target)
            if (Os.fstat(current.descriptor.fileDescriptor).st_size != size) {
                throw IOException("校验期间文件长度发生变化，请重新下载")
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    @Synchronized
    fun finish(id: String, lease: String, name: String): String {
        val target = read(id) ?: throw IOException("下载目标记录不存在")
        if (sanitize(name) != target.name) throw IOException("下载文件名已改变，请使用创建目标时的文件名重试")
        // A completed journal can be acknowledged after process restart without
        // reopening a writable descriptor or requiring the old process's lease.
        if (target.published) return target.uri
        val current = requireLease(id, lease, target)
        requireAvailable(target)
        syncDescriptor(current.descriptor)
        // This durable state also covers SAF and legacy files: after every byte
        // is synced, recovery must finish publication instead of restarting a
        // writer or discarding a completed file after a final journal failure.
        if (!target.publishing) persist(target.copy(publishing = true))
        if (target.kind == "media") {
            val updated = context.contentResolver.update(
                Uri.parse(target.uri), ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null,
            )
            if (updated != 1) throw IOException("下载已写入，但暂时无法发布文件，请继续任务重试")
        }
        persist(target.copy(published = true, publishing = false))
        return target.uri
    }

    private fun requireAvailable(target: Target) {
        when (saver.availability(target.uri)) {
            "missing" -> throw IOException("下载目标文件已被删除，请删除此任务后重新下载")
            "present" -> Unit
            else -> throw IOException("无法访问下载目标，请检查目录权限和存储设备后重试")
        }
    }

    private fun requireLease(id: String, token: String, target: Target): Lease {
        val current = leases[id] ?: throw IOException("下载目标已关闭，请重新继续任务")
        if (current.token != token || current.key != target.key) throw IOException("下载目标凭据已失效，请重新继续任务")
        return current
    }

    @Synchronized
    fun release(id: String, lease: String) {
        validateId(id)
        val current = leases[id] ?: return
        if (current.token != lease) return
        leases.remove(id)
        current.descriptor.close()
    }

    /** Caller must first stop and join every writer. Published files are never discarded here. */
    @Synchronized
    fun discard(id: String) {
        val target = read(id) ?: return
        if (target.published || target.publishing) throw IOException("文件已进入完成处理，请继续任务完成保存后再删除文件")
        closeLease(id)
        saver.deleteOrThrow(target.uri)
        deleteJournal(id)
    }

    /** Dart has durably committed completed + savedPath before acknowledging this journal. */
    @Synchronized
    fun forget(id: String) {
        val target = read(id) ?: return
        if (!target.published) throw IOException("下载尚未完成，不能移除目标记录")
        closeLease(id)
        deleteJournal(id)
    }

    @Synchronized
    fun close() {
        val pending = leases.values.toList()
        leases.clear()
        var failure: IOException? = null
        pending.forEach { lease ->
            try { lease.descriptor.close() } catch (error: IOException) {
                if (failure == null) failure = error else failure!!.addSuppressed(error)
            }
        }
        failure?.let { throw it }
    }

    private fun closeLease(id: String) { leases.remove(id)?.descriptor?.close() }

    private fun create(id: String, name: String, relativePath: String, destination: String?): Target {
        val key = UUID.randomUUID().toString()
        if (destination != null) {
            val tree = Uri.parse(destination)
            if (tree.scheme != "content" || !DocumentsContract.isTreeUri(tree)) throw IOException("请选择有效的下载目录")
            var parent = DocumentFile.fromTreeUri(context, tree) ?: throw IOException("无法访问所选下载目录")
            relativePath.split('/').filter(String::isNotEmpty).forEach { segment ->
                parent = parent.findFile(segment)?.takeIf(DocumentFile::isDirectory)
                    ?: parent.createDirectory(segment) ?: throw IOException("无法创建下载子目录")
            }
            val actual = uniqueName(name) { parent.findFile(it) != null }
            val file = parent.createFile(mimeOf(actual), actual) ?: throw IOException("无法创建下载文件")
            return Target(id, key, file.uri.toString(), "tree", name, actual, relativePath, destination)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val base = listOf(Environment.DIRECTORY_DOWNLOADS, relativePath).filter(String::isNotEmpty).joinToString("/")
            val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
            val resolver = context.contentResolver
            val actual = uniqueName(name) { candidate ->
                resolver.query(collection, arrayOf(MediaStore.Downloads._ID),
                    "${MediaStore.Downloads.DISPLAY_NAME}=? AND ${MediaStore.Downloads.RELATIVE_PATH}=?",
                    arrayOf(candidate, "$base/"), null)?.use { it.moveToFirst() } == true ||
                    resolver.query(collection, arrayOf(MediaStore.Downloads._ID),
                        "${MediaStore.Downloads.DISPLAY_NAME}=? AND ${MediaStore.Downloads.RELATIVE_PATH}=?",
                        arrayOf(candidate, base), null)?.use { it.moveToFirst() } == true
            }
            val uri = resolver.insert(collection, ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, actual)
                put(MediaStore.Downloads.MIME_TYPE, mimeOf(actual))
                put(MediaStore.Downloads.RELATIVE_PATH, base)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }) ?: throw IOException("无法创建下载文件")
            return Target(id, key, uri.toString(), "media", name, actual, relativePath, null)
        }
        val publicRoot = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), relativePath)
        val permitted = ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        val directory = publicRoot.takeIf { permitted && runCatching { it.mkdirs() || it.isDirectory }.getOrDefault(false) }
            ?: File(context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                ?: throw IOException("下载存储空间不可用"), relativePath).apply {
                check(mkdirs() || isDirectory) { "无法创建下载目录" }
            }
        var file: File
        do { file = File(directory, uniqueName(name) { File(directory, it).exists() }) } while (!file.createNewFile())
        try {
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
            return Target(id, key, uri.toString(), "legacy", name, file.name, relativePath, null)
        } catch (error: Throwable) {
            file.delete()
            throw error
        }
    }

    private fun journal(id: String): AtomicFile {
        validateId(id)
        return AtomicFile(File(journalRoot, "$id.json"))
    }

    private fun read(id: String): Target? {
        val journal = journal(id)
        if (!journal.baseFile.exists() && !File(journalRoot, "$id.json.bak").exists()) return null
        try {
            val value = JSONObject(journal.readFully().toString(Charsets.UTF_8))
            val target = Target(value.getString("id"), value.getString("key"), value.getString("uri"),
                value.getString("kind"), value.getString("name"), value.getString("actualName"),
                value.getString("relativePath"), if (value.isNull("destination")) null else value.getString("destination"),
                value.getBoolean("published"), value.optBoolean("publishing"))
            check(value.getInt("version") == 1 && target.id == id && target.key.matches(KEY) &&
                target.kind in setOf("tree", "media", "legacy") && Uri.parse(target.uri).scheme == "content")
            return target
        } catch (error: Exception) {
            throw IOException("下载目标记录无法读取，原文件已保留，请重新打开应用后重试", error)
        }
    }

    private fun persist(target: Target) {
        writeJournal(journal(target.id), target.json().toString().toByteArray(Charsets.UTF_8))
        // Update only after the durable write succeeds, including publishing
        // state when a later provider/journal operation needs to be retried.
        leases[target.id]?.target = target
    }

    private fun deleteJournal(id: String) {
        val journal = journal(id)
        journal.delete()
        if (journal.baseFile.exists() || File(journalRoot, "$id.json.bak").exists()) throw IOException("下载目标记录暂时无法清理")
    }

    companion object {
        private const val MAX_IO_BYTES = 1024L * 1024
        private val ID = Regex("[A-Za-z0-9_-]{1,100}")
        private val KEY = Regex("[0-9a-fA-F-]{36}")
        private fun validateId(id: String) { require(ID.matches(id)) { "无效的下载任务编号" } }
        private fun sanitize(value: String): String = value.replace(Regex("[\\x00-\\x1f\\x7f\\\\/:*?\"<>|]"), "_")
            .trim().trimEnd('.', ' ').take(180).ifBlank { "download.bin" }
        private fun cleanPath(value: String) = value.replace('\\', '/').split('/').map(String::trim)
            .filter { it.isNotEmpty() && it != "." && it != ".." }.joinToString("/", transform = ::sanitize)
        private fun uniqueName(name: String, exists: (String) -> Boolean): String {
            val dot = name.lastIndexOf('.').takeIf { it > 0 } ?: name.length
            for (number in 0 until 10000) {
                val candidate = if (number == 0) name else "${name.substring(0, dot)} ($number)${name.substring(dot)}"
                if (!exists(candidate)) return candidate
            }
            throw IOException("同名文件过多，请更改下载文件名")
        }
        private fun mimeOf(name: String): String = when (name.substringAfterLast('.', "").lowercase()) {
            "ts" -> "video/mp2t"
            "m3u8" -> "application/vnd.apple.mpegurl"
            else -> android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase())
                ?: "application/octet-stream"
        }
        private fun seekablePath(descriptor: ParcelFileDescriptor): String {
            val fd = descriptor.fileDescriptor
            val stat = Os.fstat(fd)
            if (!OsConstants.S_ISREG(stat.st_mode)) throw IOException("目标不是可随机访问的文件")
            Os.lseek(fd, 0L, OsConstants.SEEK_CUR)
            // Equal-length truncation checks write/truncate support without changing any bytes.
            Os.ftruncate(fd, stat.st_size)
            // This is only a locator for native dup(). Android may reject
            // reopening /proc/self/fd even after granting the document handle.
            return "/proc/self/fd/${descriptor.fd}"
        }
        private fun writeAtomic(file: AtomicFile, bytes: ByteArray) {
            val stream = file.startWrite()
            try { stream.write(bytes); file.finishWrite(stream) }
            catch (error: Throwable) { file.failWrite(stream); throw error }
        }
    }
}
