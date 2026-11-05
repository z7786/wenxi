package com.asterlink.app

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException

class AppUpdatePackage(private val context: Context) {
    @Suppress("DEPRECATION")
    fun prepare(path: String, expectedVersion: String, expectedBuild: Long): String {
        val folder = updateFolder(context)
        val cutoff = System.currentTimeMillis() - 7L * 24 * 60 * 60 * 1000
        folder.listFiles()?.filter { it.name.startsWith("update-") && it.extension == "apk" && it.lastModified() < cutoff }
            ?.forEach { it.delete() }
        val copy = File.createTempFile("update-", ".apk", folder)
        try {
            val uri = Uri.parse(path)
            val expectedSize = when {
                File(path).isAbsolute -> File(path).length()
                uri.scheme == "file" -> File(requireNotNull(uri.path)).length()
                else -> runCatching {
                    context.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                        val column = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (column >= 0 && cursor.moveToFirst() && !cursor.isNull(column)) cursor.getLong(column) else null
                    }
                }.getOrNull()
            }
            val input = when {
                File(path).isAbsolute -> FileInputStream(File(path))
                uri.scheme == "content" -> context.contentResolver.openInputStream(uri)
                uri.scheme == "file" -> FileInputStream(File(requireNotNull(uri.path)))
                else -> null
            } ?: throw IOException("无法读取下载的安装包")
            copyPackage(input, copy, expectedSize)
            val pm = context.packageManager
            val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
            val candidate = pm.getPackageArchiveInfo(copy.absolutePath, flags)
                ?: throw IOException("下载内容不是有效的 APK 安装包，请重新下载")
            val installed = pm.getPackageInfo(context.packageName, flags)
            validate(candidate, installed, expectedVersion, expectedBuild)
            return copy.absolutePath
        } catch (error: Exception) {
            copy.delete()
            throw error
        }
    }

    companion object {
        internal fun updateFolder(context: Context): File {
            // OEM installers may delegate scanning to a process that cannot traverse private cache paths.
            val roots = listOfNotNull(context.externalCacheDir, context.cacheDir)
            for (root in roots) {
                val folder = File(root, "app_updates")
                if (runCatching { (folder.isDirectory || folder.mkdirs()) && folder.canWrite() }.getOrDefault(false)) return folder
            }
            throw IOException("无法创建安装包缓存，请检查存储空间")
        }

        internal fun copyPackage(input: java.io.InputStream, copy: File, expectedSize: Long?) {
            try {
                val bytes = input.use { source ->
                    FileOutputStream(copy).use { target ->
                        val count = source.copyTo(target)
                        target.flush()
                        target.fd.sync()
                        count
                    }
                }
                if (bytes <= 0 || (expectedSize != null && expectedSize > 0 && bytes != expectedSize)) {
                    throw IOException("安装包不完整，请重新下载")
                }
            } catch (error: Exception) {
                copy.delete()
                throw error
            }
        }

        @Suppress("DEPRECATION")
        private fun code(info: PackageInfo): Long =
            if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

        private fun normalizedVersion(value: String): String = value.trim().removePrefix("v").substringBefore('+')

        @Suppress("DEPRECATION")
        internal fun validate(candidate: PackageInfo, installed: PackageInfo, expectedVersion: String, expectedBuild: Long) {
            require(candidate.packageName == installed.packageName) { "安装包包名与当前应用不一致，请使用正确的更新链接" }
            require(code(candidate) > code(installed)) { "下载的安装包不是更新版本，请检查更新链接" }
            require(expectedBuild <= 0 || code(candidate) == expectedBuild) { "安装包构建号与更新提示不一致，请重新下载" }
            require(normalizedVersion(candidate.versionName.orEmpty()) == normalizedVersion(expectedVersion)) {
                "安装包版本与更新提示不一致，请检查更新链接"
            }
            require(Build.VERSION.SDK_INT < 24 || candidate.applicationInfo?.minSdkVersion?.let { it <= Build.VERSION.SDK_INT } != false) {
                "此更新不支持当前 Android 系统版本"
            }
            val matches = if (Build.VERSION.SDK_INT >= 28) {
                val current = installed.signingInfo
                val next = candidate.signingInfo
                if (current == null || next == null) false
                else if (current.hasMultipleSigners() || next.hasMultipleSigners()) {
                    sameSigners(current.apkContentsSigners, next.apkContentsSigners)
                } else {
                    val currentSigner = current.signingCertificateHistory?.lastOrNull()
                    currentSigner != null && next.signingCertificateHistory?.contains(currentSigner) == true
                }
            } else sameSigners(installed.signatures, candidate.signatures)
            require(matches) { "安装包签名与当前应用不一致，无法覆盖更新" }
        }

        private fun sameSigners(a: Array<Signature>?, b: Array<Signature>?): Boolean =
            !a.isNullOrEmpty() && !b.isNullOrEmpty() && a.toSet() == b.toSet()
    }
}
