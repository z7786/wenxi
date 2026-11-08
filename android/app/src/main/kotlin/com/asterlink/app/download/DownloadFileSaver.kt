package com.asterlink.app.download

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import androidx.annotation.RequiresApi
import androidx.core.content.FileProvider
import androidx.core.content.ContextCompat
import androidx.documentfile.provider.DocumentFile
import java.io.File
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream

class DownloadFileSaver(private val context: Context) {
    private val creationLock = Any()

    fun save(source: File, fileName: String, relativePath: String, treeUri: String?, checkpoint: (Int) -> Unit = {}): String {
        checkpoint(0)
        val path = relativePath.replace('\\', '/').split('/').map(String::trim)
            .filter { it.isNotEmpty() && it != "." && it != ".." }.joinToString("/", transform = ::sanitize)
        return if (!treeUri.isNullOrBlank()) {
            saveToTree(source, fileName, path, Uri.parse(treeUri), checkpoint).toString()
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            saveToMediaStore(source, fileName, path, checkpoint).toString()
        } else {
            saveLegacy(source, fileName, path, checkpoint).toString()
        }
    }

    /** Unknown document providers are budgeted conservatively; removable SAF volumes are separate. */
    fun mayShareCacheVolume(treeUri: String?): Boolean {
        if (treeUri.isNullOrBlank()) return true
        return runCatching {
            val uri = Uri.parse(treeUri)
            if (uri.authority != "com.android.externalstorage.documents") return@runCatching true
            val volume = DocumentsContract.getTreeDocumentId(uri).substringBefore(':')
            !volume.matches(Regex("[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}"))
        }.getOrDefault(true)
    }

    fun delete(uriString: String?): Boolean {
        if (uriString.isNullOrBlank()) return false
        return runCatching { deleteOrThrow(uriString); true }.getOrDefault(false)
    }

    /** Both the list and deletion use the same distinction between absent and inaccessible. */
    fun availability(path: String?): String {
        if (path.isNullOrBlank()) return "missing"
        return try {
            val uri = Uri.parse(path)
            if (uri.scheme == "content") {
                if (runCatching { context.contentResolver.getType(uri) }.getOrNull() == DocumentsContract.Document.MIME_TYPE_DIR) {
                    return "inaccessible"
                }
                try {
                    // A null descriptor can mean a crashed provider, not an absent file.
                    context.contentResolver.openFileDescriptor(uri, "r")?.use { "present" }
                        ?: "inaccessible"
                } catch (error: FileNotFoundException) {
                    when {
                        permissionDenied(error) -> "inaccessible"
                        absent(error) -> "missing"
                        else -> contentMetadataAvailability(uri)
                    }
                } catch (error: IllegalArgumentException) {
                    if (permissionDenied(error)) "inaccessible" else externalTreeAvailability(uri)
                }
            } else {
                val file = localFile(path)
                val stat = Os.stat(file.absolutePath)
                if (!OsConstants.S_ISREG(stat.st_mode)) "inaccessible"
                else FileInputStream(file).use { "present" }
            }
        } catch (error: Exception) {
            if (absent(error)) "missing" else "inaccessible"
        }
    }

    private fun contentMetadataAvailability(uri: Uri): String = try {
        val resolver = context.contentResolver
        val columns = arrayOf(OpenableColumns.DISPLAY_NAME)
        val cursor = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            resolver.query(uri, columns, Bundle.EMPTY, null)
        } else {
            resolver.query(uri, columns, null, null, null)
        }
        cursor?.use { if (it.moveToFirst()) "inaccessible" else "missing" }
            // DocumentsProvider converts queryDocument's FileNotFoundException
            // to a null Cursor. Here openFile has already reported not-found.
            ?: if (DocumentsContract.isDocumentUri(context, uri)) "missing" else "inaccessible"
    } catch (error: FileNotFoundException) {
        if (permissionDenied(error)) "inaccessible" else "missing"
    } catch (_: Exception) {
        "inaccessible"
    }

    private fun externalTreeAvailability(uri: Uri): String {
        // ExternalStorageProvider wraps a missing child in IllegalArgumentException while
        // enforcing a tree grant. Verify absence by listing within that same grant; error
        // messages and an inaccessible document alone are not proof of deletion.
        if (uri.authority != "com.android.externalstorage.documents" ||
            !DocumentsContract.isTreeUri(uri)) return "inaccessible"
        return try {
            val treeId = DocumentsContract.getTreeDocumentId(uri)
            val documentId = DocumentsContract.getDocumentId(uri)
            val volume = treeId.substringBefore(':')
            if (!treeId.contains(':') || volume.isBlank() ||
                documentId.substringBefore(':') != volume || !documentId.contains(':')) return "inaccessible"
            fun segments(id: String) = id.substringAfter(':').let {
                if (it.isEmpty()) emptyList() else it.split('/')
            }
            val parentSegments = segments(treeId)
            val childSegments = segments(documentId)
            if (childSegments.size > 64 || childSegments.size <= parentSegments.size ||
                childSegments.take(parentSegments.size) != parentSegments ||
                (parentSegments + childSegments).any { it.isEmpty() || it == "." || it == ".." || it.contains('\\') }) {
                return "inaccessible"
            }
            val resolver = context.contentResolver
            var parentId = treeId
            var inspected = 0
            for (depth in parentSegments.size until childSegments.size) {
                val parentUri = DocumentsContract.buildDocumentUriUsingTree(uri, parentId)
                if (resolver.getType(parentUri) != DocumentsContract.Document.MIME_TYPE_DIR) return "inaccessible"
                val expectedId = "$volume:${childSegments.take(depth + 1).joinToString("/")}"
                val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(uri, parentId)
                val columns = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    resolver.query(childrenUri, columns, Bundle.EMPTY, null)
                } else {
                    resolver.query(childrenUri, columns, null, null, null)
                }
                val found = result?.use { cursor ->
                    val column = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                    if (column < 0) return "inaccessible"
                    var matched = false
                    while (cursor.moveToNext()) {
                        if (++inspected > 100_000) return "inaccessible"
                        if (cursor.getString(column) == expectedId) matched = true
                    }
                    if (cursor.extras.getBoolean(DocumentsContract.EXTRA_LOADING, false) ||
                        cursor.extras.containsKey(DocumentsContract.EXTRA_ERROR)) return "inaccessible"
                    matched
                } ?: return "inaccessible"
                if (!found) return "missing"
                parentId = expectedId
            }
            "inaccessible"
        } catch (_: Exception) {
            "inaccessible"
        }
    }

    private fun permissionDenied(error: Throwable): Boolean = generateSequence(error) { it.cause }
        .take(8).any {
            it is SecurityException ||
                (it is ErrnoException && it.errno in setOf(OsConstants.EACCES, OsConstants.EPERM)) ||
                (it is FileNotFoundException && Regex("\\b(EACCES|EPERM)\\b").containsMatchIn(it.message.orEmpty()))
        }

    private fun absent(error: Throwable): Boolean = !permissionDenied(error) &&
        generateSequence(error) { it.cause }.take(8).any {
            (it is ErrnoException && it.errno in setOf(OsConstants.ENOENT, OsConstants.ENOTDIR)) ||
                (it is FileNotFoundException && Regex("\\b(ENOENT|ENOTDIR)\\b").containsMatchIn(it.message.orEmpty()))
        }

    private fun localFile(path: String): File {
        File(path).takeIf(File::isAbsolute)?.let { return it }
        val uri = Uri.parse(path)
        val file = when (uri.scheme) {
            "file" -> File(uri.path?.takeIf(String::isNotBlank) ?: throw IOException("文件位置无效"))
            null -> File(path)
            else -> throw IOException("无法识别已保存文件的位置")
        }
        if (!file.isAbsolute) throw IOException("已保存文件路径无效")
        return file
    }

    /** Already absent files succeed; access failures leave a record available for retry. */
    fun deleteOrThrow(uriString: String?) {
        if (uriString.isNullOrBlank()) return
        if (availability(uriString) == "missing") return
        val uri = Uri.parse(uriString)
        try {
            val deleted = when (uri.scheme) {
                "content" -> {
                    val resolver = context.contentResolver
                    if (runCatching { resolver.getType(uri) }.getOrNull() == DocumentsContract.Document.MIME_TYPE_DIR) {
                        throw IOException("文件位置已变为文件夹，已保留下载记录")
                    }
                    if (DocumentsContract.isDocumentUri(context, uri)) {
                        DocumentsContract.deleteDocument(resolver, uri)
                    } else {
                        resolver.delete(uri, null, null) > 0
                    }
                }
                else -> {
                    val file = localFile(uriString)
                    if (!OsConstants.S_ISREG(Os.lstat(file.absolutePath).st_mode)) {
                        throw IOException("文件位置发生变化，已保留下载记录")
                    }
                    file.delete()
                }
            }
            if (!deleted) throw IOException("文件未能删除，请检查目录权限后重试")
        } catch (error: Exception) {
            // Providers may report false, zero, or an exception after a raced deletion.
            // Recheck instead of treating every FileNotFoundException as success.
            if (permissionDenied(error) || availability(uriString) != "missing") throw error
        }
    }

    private fun saveToTree(source: File, fileName: String, relativePath: String, treeUri: Uri, checkpoint: (Int) -> Unit): Uri {
        val document = synchronized(creationLock) {
            var parent = DocumentFile.fromTreeUri(context, treeUri)
                ?: error("无法访问选择的目录")
            relativePath.split('/').filter(String::isNotEmpty).forEach { segment ->
                checkpoint(0)
                parent = parent.findFile(segment)?.takeIf(DocumentFile::isDirectory)
                    ?: parent.createDirectory(segment)
                    ?: error("无法创建目录：$segment")
            }
            val uniqueName = uniqueDocumentName(parent, sanitize(fileName))
            parent.createFile(mimeOf(uniqueName), uniqueName) ?: error("无法创建文件")
        }
        try {
            context.contentResolver.openOutputStream(document.uri, "w")?.use { copy(source, it, checkpoint) }
                ?: error("无法写入文件")
            checkpoint(0)
            return document.uri
        } catch (error: Throwable) {
            runCatching { document.delete() }
            throw error
        }
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun saveToMediaStore(source: File, fileName: String, relativePath: String, checkpoint: (Int) -> Unit): Uri {
        val resolver = context.contentResolver
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val basePath = buildString {
            append(Environment.DIRECTORY_DOWNLOADS)
            relativePath.trim('/').takeIf(String::isNotBlank)?.let { append('/').append(it) }
        }
        val uri = synchronized(creationLock) {
            val uniqueName = uniqueMediaName(collection, basePath, sanitize(fileName))
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, uniqueName)
                put(MediaStore.Downloads.MIME_TYPE, mimeOf(uniqueName))
                put(MediaStore.Downloads.RELATIVE_PATH, basePath)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            resolver.insert(collection, values) ?: error("无法创建下载文件")
        }
        try {
            resolver.openOutputStream(uri, "w")?.use { copy(source, it, checkpoint) } ?: error("无法写入下载文件")
            checkpoint(0)
            resolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
            return uri
        } catch (error: Throwable) {
            runCatching { resolver.delete(uri, null, null) }
            throw error
        }
    }

    private fun saveLegacy(source: File, fileName: String, relativePath: String, checkpoint: (Int) -> Unit): Uri {
        val publicRoot = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        val canWritePublic = ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        val targetDir = File(publicRoot, relativePath).takeIf { root -> canWritePublic &&
            runCatching { root.mkdirs() || root.isDirectory }.getOrDefault(false)
        } ?: File(checkNotNull(context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)) {
            "下载存储空间不可用"
        }, relativePath).apply { check(mkdirs() || isDirectory) { "无法创建下载目录" } }
        val target = synchronized(creationLock) {
            generateSequence { uniqueFile(targetDir, sanitize(fileName)) }.first { it.createNewFile() }
        }
        try {
            FileOutputStream(target).use { output ->
                copy(source, output, checkpoint)
                output.fd.sync()
            }
            checkpoint(0)
            return FileProvider.getUriForFile(context, "${context.packageName}.files", target)
        } catch (error: Throwable) {
            target.delete()
            throw error
        }
    }

    private fun copy(source: File, output: OutputStream, checkpoint: (Int) -> Unit) {
        FileInputStream(source).use { input ->
            val buffer = ByteArray(256 * 1024)
            while (true) {
                checkpoint(0)
                val count = input.read(buffer)
                if (count < 0) break
                output.write(buffer, 0, count)
                checkpoint(count)
            }
        }
    }

    private fun uniqueDocumentName(parent: DocumentFile, fileName: String): String {
        if (parent.findFile(fileName) == null) return fileName
        return generateSequence(1) { it + 1 }.map { numbered(fileName, it) }
            .first { parent.findFile(it) == null }
    }

    private fun uniqueMediaName(collection: Uri, relativePath: String, fileName: String): String {
        val resolver = context.contentResolver
        fun exists(name: String): Boolean = resolver.query(
            collection,
            arrayOf(MediaStore.Downloads._ID),
            "${MediaStore.Downloads.DISPLAY_NAME}=? AND ${MediaStore.Downloads.RELATIVE_PATH}=?",
            arrayOf(name, relativePath),
            null
        )?.use { it.moveToFirst() } == true
        if (!exists(fileName)) return fileName
        return generateSequence(1) { it + 1 }.map { numbered(fileName, it) }.first { !exists(it) }
    }

    private fun uniqueFile(directory: File, fileName: String): File {
        val direct = File(directory, fileName)
        if (!direct.exists()) return direct
        return generateSequence(1) { it + 1 }.map { File(directory, numbered(fileName, it)) }.first { !it.exists() }
    }

    private fun numbered(fileName: String, index: Int): String {
        val dot = fileName.lastIndexOf('.')
        return if (dot > 0) "${fileName.substring(0, dot)} ($index)${fileName.substring(dot)}" else "$fileName ($index)"
    }

    private fun sanitize(value: String): String = value.replace(Regex("[\\/:*?\"<>|]"), "_").trim().ifBlank { "download.bin" }

    private fun mimeOf(fileName: String): String = when (fileName.substringAfterLast('.', "").lowercase()) {
        "apk" -> "application/vnd.android.package-archive"
        "json" -> "application/json"
        "ts" -> "video/mp2t"
        "m3u8" -> "application/vnd.apple.mpegurl"
        "jpg", "jpeg" -> "image/jpeg"
        "png" -> "image/png"
        "gif" -> "image/gif"
        "webp" -> "image/webp"
        "mp4" -> "video/mp4"
        "mkv" -> "video/x-matroska"
        "mp3" -> "audio/mpeg"
        "m4a" -> "audio/mp4"
        "txt", "log", "md" -> "text/plain"
        "pdf" -> "application/pdf"
        "zip" -> "application/zip"
        "7z" -> "application/x-7z-compressed"
        "rar" -> "application/vnd.rar"
        else -> android.webkit.MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(fileName.substringAfterLast('.', "").lowercase())
            ?: "application/octet-stream"
    }
}
