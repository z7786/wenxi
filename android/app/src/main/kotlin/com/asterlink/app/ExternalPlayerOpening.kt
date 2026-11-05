package com.asterlink.app

import android.app.Activity
import android.app.AlertDialog
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.net.Uri
import android.view.View
import android.view.ViewGroup
import android.widget.ArrayAdapter
import android.widget.TextView
import java.io.FileNotFoundException
import java.text.Collator
import java.util.Locale

/** An explicit app choice gives a reliable cancel result without depending on
 * the chosen player's (often absent) activity result protocol. */
class ExternalPlayerOpening(
    private val context: Context,
    private val activity: () -> Activity?,
    private val files: FileOpening,
) {
    private val history = context.getSharedPreferences("external-player-history", Context.MODE_PRIVATE)
    private var dialog: AlertDialog? = null
    private var owner: Activity? = null
    private var session: String? = null

    fun open(url: String, title: String, positionMs: Long, session: String = "", complete: (Boolean, FileOpenFailure?) -> Unit) {
        if (dialog != null) {
            complete(false, FileOpenFailure("busy", "请先关闭当前播放器选择窗口"))
            return
        }
        try {
            val current = activity()?.takeUnless { it.isFinishing || it.isDestroyed }
                ?: throw FileOpenFailure("activity", "请回到播放器后重试")
            val intent = prepare(url, title, positionMs)
            val targets = targets(intent)
            if (targets.isEmpty()) throw FileOpenFailure("no_player", "未找到可播放此视频的第三方播放器，请先安装 VLC、MX Player 等播放器")
            val labels = targets.map { it.loadLabel(context.packageManager).toString() }
            val recent = history.getString("recent", "").orEmpty().split('\n')
            val adapter = object : ArrayAdapter<String>(current, android.R.layout.select_dialog_item, labels) {
                override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
                    val view = super.getView(position, convertView, parent) as TextView
                    val icon = targets[position].loadIcon(context.packageManager)
                    val size = (32 * current.resources.displayMetrics.density).toInt()
                    icon.setBounds(0, 0, size, size)
                    view.setCompoundDrawablesRelative(icon, null, null, null)
                    view.compoundDrawablePadding = (16 * current.resources.displayMetrics.density).toInt()
                    view.text = labels[position] + if (targets[position].activityInfo.packageName in recent) "  · 最近使用" else ""
                    return view
                }
            }
            var completed = false
            fun finish(opened: Boolean, error: FileOpenFailure? = null) {
                if (completed) return
                completed = true
                complete(opened, error)
            }
            val chooser = AlertDialog.Builder(current)
                .setTitle("选择第三方播放器")
                .setAdapter(adapter, null)
                .setNegativeButton("取消") { _, _ -> finish(false) }
                .create()
            owner = current
            this.session = session
            dialog = chooser
            var choosing = false
            chooser.setOnDismissListener {
                if (dialog === chooser) { dialog = null; owner = null; this.session = null }
                if (!choosing) finish(false)
            }
            chooser.show()
            chooser.listView.setOnItemClickListener { _, _, index, _ ->
                choosing = true
                val target = targets[index].activityInfo
                chooser.dismiss()
                try {
                    current.startActivity(Intent(intent).setComponent(ComponentName(target.packageName, target.name)))
                    history.edit().putString("recent", (listOf(target.packageName) +
                        recent.filter { it.isNotBlank() && it != target.packageName }).take(12).joinToString("\n")).apply()
                    finish(true)
                } catch (error: Exception) { finish(false, failure(error)) }
            }
        } catch (error: Exception) {
            dialog = null
            owner = null
            this.session = null
            complete(false, failure(error))
        }
    }

    fun dismiss(current: Activity? = null, session: String? = null) {
        if ((current == null || current === owner) && (session == null || session == this.session)) dialog?.dismiss()
    }

    fun prepare(url: String, title: String, positionMs: Long): Intent {
        val parsed = Uri.parse(url)
        val file = if (parsed.scheme in setOf("http", "https")) {
            require(!parsed.host.isNullOrBlank() && parsed.userInfo.isNullOrEmpty())
            FileOpening.OpenFile(parsed, videoMime(title, parsed))
        } else {
            val local = files.prepare(url, title)
            local.copy(mime = videoMime(title, local.uri, local.mime))
        }
        return FileOpening.readableIntent(file, false)
            .putExtra(Intent.EXTRA_TITLE, title)
            .putExtra("title", title)
            .putExtra("position", positionMs.coerceIn(0, Int.MAX_VALUE.toLong()).toInt())
            .putExtra("extra_start_time", positionMs.coerceAtLeast(0))
    }

    @Suppress("DEPRECATION")
    fun targets(intent: Intent): List<ResolveInfo> {
        val collator = Collator.getInstance()
        val recent = history.getString("recent", "").orEmpty().split('\n')
        val types = listOfNotNull(intent.type, "video/*", "application/x-mpegurl".takeIf { intent.type?.contains("mpegurl") == true }).distinct()
        return types.flatMap { type -> context.packageManager.queryIntentActivities(Intent(intent).setDataAndType(intent.data, type), PackageManager.MATCH_DEFAULT_ONLY) }
            .filter {
                val info = it.activityInfo
                info != null && info.packageName != context.packageName && info.exported && info.enabled &&
                    (info.permission == null || context.checkSelfPermission(info.permission) == PackageManager.PERMISSION_GRANTED)
            }
            .distinctBy { it.activityInfo.packageName }
            .sortedWith { a, b ->
                val left = recent.indexOf(a.activityInfo.packageName).takeIf { it >= 0 } ?: Int.MAX_VALUE
                val right = recent.indexOf(b.activityInfo.packageName).takeIf { it >= 0 } ?: Int.MAX_VALUE
                if (left != right) left.compareTo(right) else
                    collator.compare(a.loadLabel(context.packageManager).toString(), b.loadLabel(context.packageManager).toString()) }
    }

    companion object {
        fun videoMime(title: String, uri: Uri, stored: String? = null): String {
            val path = uri.path.orEmpty().lowercase(Locale.ROOT)
            if (path.endsWith(".m3u8") || title.lowercase(Locale.ROOT).endsWith(".m3u8")) return "application/vnd.apple.mpegurl"
            if (path.endsWith(".mpd") || title.lowercase(Locale.ROOT).endsWith(".mpd")) return "application/dash+xml"
            val mime = FileOpening.mimeType(title, stored)
            return if (mime.startsWith("video/") || mime in setOf("application/mp4", "application/x-matroska")) mime else "video/*"
        }

        private fun failure(error: Exception) = when (error) {
            is FileOpenFailure -> error
            is ActivityNotFoundException -> FileOpenFailure("no_player", "播放器已不可用，请重新选择其他播放器")
            is SecurityException -> FileOpenFailure("permission", "无法授权播放器读取视频，请检查文件访问权限")
            is FileNotFoundException -> FileOpenFailure("missing", "视频文件不存在或已被移动")
            else -> FileOpenFailure("external_player", "无法打开第三方播放器，请重试")
        }
    }
}
