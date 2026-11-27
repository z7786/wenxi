package com.asterlink.app.download

import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import java.io.File

/** Stable physical-volume accounting for the cache and the selected destination. */
class DownloadStorage(private val context: Context) {
    private fun volume(file: File): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            context.getSystemService(StorageManager::class.java)?.getStorageVolume(file)?.let {
                return "volume:${it.uuid?.lowercase() ?: "primary"}"
            }
        }
        val path = file.canonicalPath
        val primary = Environment.getExternalStorageDirectory().canonicalPath
        if (path.startsWith(context.filesDir.parentFile!!.canonicalPath + File.separator) ||
            path == primary || path.startsWith(primary + File.separator)) {
            return "volume:primary"
        }
        val external = path.substringBefore("/Android/")
        return "volume:${external.substringAfterLast('/').lowercase()}"
    }

    private fun documentVolume(uri: Uri): String? {
        if (uri.authority != "com.android.externalstorage.documents") return null
        return runCatching { DocumentsContract.getTreeDocumentId(uri).substringBefore(':').lowercase() }.getOrNull()
    }

    private fun documentRoot(uri: Uri): File? {
        val id = documentVolume(uri) ?: return null
        if (id == "primary") return Environment.getExternalStorageDirectory()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            context.getSystemService(StorageManager::class.java)?.storageVolumes
                ?.firstOrNull { it.uuid.equals(id, ignoreCase = true) }?.directory?.let { return it }
        }
        return context.getExternalFilesDirs(null).filterNotNull()
            .firstOrNull { volume(it) == "volume:$id" }
            ?.let { File(it.canonicalPath.substringBefore("/Android/")) }
    }

    internal fun documentDirectory(uri: Uri): Pair<File, File>? {
        if (uri.authority != "com.android.externalstorage.documents" || !DocumentsContract.isTreeUri(uri)) return null
        val id = DocumentsContract.getTreeDocumentId(uri)
        if (!id.contains(':')) return null
        val path = id.substringAfter(':')
        val segments = path.split('/')
        if (path.isEmpty() || segments.size > 64 || segments.any {
                it.isEmpty() || it == "." || it == ".." || it.contains('\\') || it.contains('\u0000')
            }) return null
        val root = documentRoot(uri)?.canonicalFile ?: return null
        return root to File(root, path)
    }

    fun plan(cache: File, destination: String?): Map<String, Any> {
        val uri = destination?.takeIf { it.isNotBlank() }?.let(Uri::parse)
        val path = uri?.toString() ?: Environment.getExternalStorageDirectory().absolutePath
        val target = if (uri?.scheme == "content") {
            documentVolume(uri)?.let { "volume:$it" } ?: "provider:$uri"
        } else volume(File(path))
        return mapOf(
            "cache" to mapOf("volume" to volume(cache), "path" to cache.absolutePath),
            "target" to mapOf("volume" to target, "path" to path)
        )
    }

    fun freeBytes(path: String): Long = runCatching {
        val uri = Uri.parse(path)
        val file = if (uri.scheme == "content") documentRoot(uri) ?: return -1L
            else File(path)
        if (!file.exists()) -1L else file.usableSpace
    }.getOrDefault(-1L)
}
