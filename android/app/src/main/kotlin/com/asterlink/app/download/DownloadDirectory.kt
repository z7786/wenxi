package com.asterlink.app.download

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Process
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import java.io.IOException

/** Reopen the selected directory, restoring only its original, authorized location. */
internal class DownloadDirectory(private val context: Context) {
    fun open(tree: Uri): DocumentFile {
        if (tree.scheme != "content" || !DocumentsContract.isTreeUri(tree)) {
            throw DownloadDirectoryException("请选择有效的下载目录")
        }
        val directory = DocumentFile.fromTreeUri(context, tree)
            ?: throw DownloadDirectoryException("无法访问所选下载目录")
        if (directory.isDirectory) return directory

        val access = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        val granted = context.checkUriPermission(tree, Process.myPid(), Process.myUid(), access) == PackageManager.PERMISSION_GRANTED
        // Only the system external-storage provider has path-based document IDs.
        // Never interpret another provider's opaque IDs as filesystem paths.
        val location = DownloadStorage(context).documentDirectory(tree)
            ?: throw DownloadDirectoryException("下载目录不可用，请检查存储设备或在下载设置中重新选择原目录")
        val (volume, target) = location
        if (!volume.isDirectory) throw DownloadDirectoryException("下载存储设备不可用，请连接后重试")
        if (target.exists() && !target.isDirectory) {
            throw DownloadDirectoryException("下载目录无法访问，请检查目录权限后重试")
        }
        // A path changed to a symlink or a file must not redirect recreation.
        var current = target
        while (current != volume) {
            if (current.canonicalFile != current.absoluteFile || current.exists() && !current.isDirectory) {
                throw DownloadDirectoryException("下载目录位置发生变化，请在下载设置中重新选择原目录")
            }
            current = current.parentFile ?: throw DownloadDirectoryException("下载目录位置无效")
        }
        // Deleting a selected tree can revoke just that grant. An independently
        // granted parent can recreate it and remains the URI used for writing.
        restoreThroughParentGrant(tree)?.let { return it }
        // A tree grant does not grant raw filesystem access. mkdirs succeeds
        // only when Android also permits creation at this same local path.
        if (granted && (target.mkdirs() || target.isDirectory) && directory.isDirectory) return directory
        if (!granted) throw DownloadDirectoryException("下载目录授权已失效，请在下载设置中重新选择原目录")
        throw DownloadDirectoryException("下载目录已被删除且无法自动重建，请在下载设置中重新选择原目录并重试")
    }

    private fun restoreThroughParentGrant(tree: Uri): DocumentFile? {
        val id = DocumentsContract.getTreeDocumentId(tree)
        val candidates = context.contentResolver.persistedUriPermissions.filter {
            it.isReadPermission && it.isWritePermission && it.uri.authority == tree.authority &&
                DocumentsContract.isTreeUri(it.uri)
        }.map { it.uri to DocumentsContract.getTreeDocumentId(it.uri) }.filter { (_, parent) ->
            parent != id && id.startsWith(if (parent.endsWith(':')) parent else "$parent/")
        }.sortedByDescending { it.second.length }
        for ((uri, parentId) in candidates) {
            var parent = DocumentFile.fromTreeUri(context, uri)?.takeIf { it.isDirectory } ?: continue
            val segments = id.removePrefix(parentId).trimStart('/').split('/')
            for (segment in segments) {
                val child = parent.findFile(segment)
                parent = if (child != null) {
                    if (!child.isDirectory) throw DownloadDirectoryException("下载目录位置已被同名文件占用")
                    child
                } else {
                    parent.createDirectory(segment) ?: throw DownloadDirectoryException("无法重建下载目录，请检查目录权限后重试")
                }
            }
            return parent
        }
        return null
    }
}

internal class DownloadDirectoryException(message: String) : IOException(message)
