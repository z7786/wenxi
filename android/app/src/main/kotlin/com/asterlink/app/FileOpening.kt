package com.asterlink.app

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.webkit.MimeTypeMap
import android.widget.Toast
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileNotFoundException
import java.util.Locale

class FileOpenFailure(val code: String, message: String) : Exception(message)

/** Owns the one installation the user requested while Android shows source settings. */
class FileOpening(
    private val context: Context,
    private val activity: () -> Activity?,
    private val canInstall: () -> Boolean = {
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || context.packageManager.canRequestPackageInstalls()
    },
    private val localUri: (File) -> Uri = {
        FileProvider.getUriForFile(context, "${context.packageName}.files", it)
    },
) {
    data class OpenFile(val uri: Uri, val mime: String)
    private data class Pending(val file: OpenFile, val complete: (FileOpenFailure?) -> Unit)
    private var pending: Pending? = null
    private var leftForSettings = false

    fun prepare(path: String, name: String): OpenFile {
        val parsed = Uri.parse(path)
        val rawFile = File(path)
        val uri = if (rawFile.isAbsolute) localContentUri(rawFile) else when (parsed.scheme?.lowercase(Locale.ROOT)) {
            "content" -> parsed.also { require(!it.authority.isNullOrBlank()) }
            "file" -> localContentUri(File(java.net.URI(path)))
            else -> throw FileOpenFailure("location", "无法识别已保存文件的位置")
        }
        val stored = runCatching { context.contentResolver.getType(uri) }.getOrNull()
        return OpenFile(uri, mimeType(name.ifBlank { uri.lastPathSegment.orEmpty() }, stored))
    }

    private fun localContentUri(value: File): Uri {
        require(value.isAbsolute)
        val file = value.canonicalFile
        if (!file.isFile) throw FileNotFoundException()
        return localUri(file)
    }

    fun open(path: String, name: String, share: Boolean, complete: (FileOpenFailure?) -> Unit) =
        open(path, name, share, false, complete)

    fun open(path: String, name: String, share: Boolean, chooseApp: Boolean, complete: (FileOpenFailure?) -> Unit) {
        try {
            val file = prepare(path, name)
            if (share || chooseApp || file.mime != APK_MIME) {
                val intent = readableIntent(file, share)
                launch(Intent.createChooser(intent, if (share) "分享文件" else "用其他应用打开"))
                complete(null)
            } else if (pending != null) {
                complete(FileOpenFailure("busy", "请先完成当前的安装授权"))
            } else if (canInstall()) {
                launch(readableIntent(file, false))
                complete(null)
            } else {
                val current = activity() ?: throw FileOpenFailure("activity", "请回到应用后重新打开 APK")
                pending = Pending(file, complete)
                leftForSettings = false
                try {
                    current.startActivityForResult(
                        Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}")),
                        INSTALL_SETTINGS_REQUEST,
                    )
                } catch (_: Exception) {
                    pending = null
                    throw FileOpenFailure("install_settings", "无法打开安装授权设置，请在系统应用信息中允许安装未知应用后重试")
                }
            }
        } catch (error: Exception) {
            complete(failure(error))
        }
    }

    fun activityResult(requestCode: Int): Boolean {
        if (requestCode != INSTALL_SETTINGS_REQUEST) return false
        continueInstall()
        return true
    }

    fun paused() { if (pending != null) leftForSettings = true }
    fun resumed() { if (leftForSettings) continueInstall() }

    private fun continueInstall() {
        val request = pending ?: return
        // Some systems deliver both an activity result and onResume. Consume before launch.
        pending = null
        leftForSettings = false
        try {
            if (!canInstall()) throw FileOpenFailure("install_permission", "尚未允许安装未知应用，请允许后再次打开 APK")
            launch(readableIntent(request.file, false))
            request.complete(null)
        } catch (error: Exception) {
            request.complete(failure(error))
        }
    }

    fun save(state: Bundle) {
        pending?.let { state.putString(PENDING_URI, it.file.uri.toString()) }
    }

    fun restore(state: Bundle?) {
        if (pending != null) return
        val value = state?.getString(PENDING_URI) ?: return
        val uri = Uri.parse(value)
        if (uri.scheme != "content" || uri.authority.isNullOrBlank()) return
        pending = Pending(OpenFile(uri, APK_MIME)) { error ->
            if (error != null) Toast.makeText(context, error.message, Toast.LENGTH_LONG).show()
        }
        leftForSettings = true
    }

    private fun launch(intent: Intent) {
        if (intent.action == Intent.ACTION_VIEW && intent.type == APK_MIME) {
            // Keep the installer separate from the app task during an in-place update.
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val uri = intent.data
            if (uri?.scheme == "content") {
                // Some OEM installers forward the URI to their scanner without propagating the intent grant.
                @Suppress("DEPRECATION")
                val handlers = context.packageManager.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)
                for (name in handlers.mapNotNull { it.activityInfo?.packageName }.distinct()) {
                    runCatching { context.grantUriPermission(name, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
                }
            }
        }
        val current = activity()
        if (current != null) current.startActivity(intent)
        else context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    companion object {
        const val APK_MIME = "application/vnd.android.package-archive"
        const val INSTALL_SETTINGS_REQUEST = 834
        private const val PENDING_URI = "asterlink.pendingInstallUri"

        fun mimeType(name: String, stored: String?): String {
            val extension = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
            // Providers can return a generic or incorrect type for APKs and videos.
            if (extension == "apk") return APK_MIME
            return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
                ?: stored?.substringBefore(';')?.trim()?.lowercase(Locale.ROOT)
                ?.takeUnless { it.isBlank() || it == "application/octet-stream" || it == "*/*" }
                ?: "*/*"
        }

        fun readableIntent(file: OpenFile, share: Boolean): Intent {
            val intent = if (share) Intent(Intent.ACTION_SEND).setType(file.mime).putExtra(Intent.EXTRA_STREAM, file.uri)
                else Intent(Intent.ACTION_VIEW).setDataAndType(file.uri, file.mime)
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            intent.clipData = ClipData("文析助手文件", arrayOf(file.mime), ClipData.Item(file.uri))
            return intent
        }

        private fun failure(error: Exception) = when (error) {
            is FileOpenFailure -> error
            is ActivityNotFoundException -> FileOpenFailure("no_handler", "系统没有可打开此文件的应用或安装器")
            is SecurityException -> FileOpenFailure("permission", "无法读取文件或系统限制了安装，请检查文件访问和安装权限")
            is FileNotFoundException -> FileOpenFailure("missing", "文件不存在或已被移动")
            else -> FileOpenFailure("open", "无法打开此文件，请检查文件位置和访问权限")
        }
    }
}
