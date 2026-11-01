package com.asterlink.app

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel

interface DownloadServiceOwner {
    val downloadKeepAlive: DownloadKeepAlive
}

data class DownloadNotice(val active: Int, val text: String, val progress: Int = -1, val uploads: Int = 0, val lan: Int = 0) {
    companion object {
        val IDLE = DownloadNotice(0, "")
        val RECOVERING = DownloadNotice(1, "正在恢复中断的下载…")
        fun from(arguments: Map<*, *>): DownloadNotice = DownloadNotice(
            ((arguments["active"] as? Number)?.toInt() ?: 0).coerceIn(0, 10000),
            (arguments["text"] as? String ?: "正在下载").take(256),
            ((arguments["progress"] as? Number)?.toInt() ?: -1).coerceIn(-1, 100),
            ((arguments["uploads"] as? Number)?.toInt() ?: 0).coerceIn(0, 10000),
            ((arguments["lan"] as? Number)?.toInt() ?: 0).coerceIn(0, 1)
        )
    }
}

/** One coordinator for the retained Flutter engine and its foreground service.
 * Commands wait for Dart initialization; a start succeeds only after
 * startForeground. No credentials, paths or task URLs are stored here.
 */
class DownloadKeepAlive(
    private val context: Context,
    private val send: (String, (Boolean) -> Unit) -> Unit,
    private val report: (String, Throwable) -> Unit = { _, _ -> }
) {
    private val main = Handler(Looper.getMainLooper())
    private val preferences = context.getSharedPreferences("download_keepalive", Context.MODE_PRIVATE)
    private var latest = DownloadNotice.IDLE
    private var service: FlutterDownloadService? = null
    private val starts = mutableListOf<MethodChannel.Result>()
    private var starting = false
    private var ready = false
    private var recover = false
    private var discardRecovery = false
    private var pauseCommand: String? = null
    private var commandInFlight = false
    private var commandGeneration = 0
    private var timedOut = false
    private var heartbeat = 0L
    private val startTimeout = Runnable {
        if (starting) failStart(IllegalStateException("后台下载服务启动超时"))
    }
    private val pauseTimeout = Runnable {
        if (pauseCommand != null) {
            // A Dart reply may be lost during engine recovery. Invalidate the
            // old callback so returning to the app can retry this same stop.
            commandGeneration++
            commandInFlight = false
            stopService()
            report("download.pause_timeout", IllegalStateException("后台下载暂停确认超时"))
        }
    }

    val running: Boolean get() = service != null
    val wakeLockHeld: Boolean get() = service?.wakeLockHeld == true
    val waitingForRestart: Boolean get() = recover
    val recoveryExpected: Boolean get() = wanted && pauseCommand == null && !timedOut
    private var wanted: Boolean
        get() = preferences.getBoolean("wanted", false)
        set(value) {
            if (wanted != value) preferences.edit().putBoolean("wanted", value).commit()
        }

    fun appVisible() {
        timedOut = false
        if (service == null && !starting && !recover && latest.active == 0) {
            // A cold UI launch must not carry old recovery candidates into a
            // future download session, including after a user force-stop.
            wanted = false
            discardRecovery = true
        }
        dispatchCommand()
    }

    fun dartReady() {
        ready = true
        dispatchCommand()
    }

    fun update(value: DownloadNotice, result: MethodChannel.Result) {
        if (value.active == 0) {
            latest = value
            wanted = false
            stopService()
            completeStarts()
            result.success(null)
            return
        }
        if (timedOut || pauseCommand != null) {
            result.error("foreground", "后台下载已暂停，请返回应用后继续", null)
            return
        }
        latest = value
        heartbeat = SystemClock.elapsedRealtime()
        wanted = true
        val current = service
        if (current != null) {
            try {
                current.show(value)
                result.success(null)
            } catch (error: Exception) {
                result.error("foreground", "后台下载通知更新失败，请重试", null)
                failStart(error)
            }
            return
        }
        starts.add(result)
        if (starting) return
        starting = true
        main.postDelayed(startTimeout, 8000)
        try {
            ContextCompat.startForegroundService(context, Intent(context, FlutterDownloadService::class.java))
        } catch (error: Exception) {
            failStart(error)
        }
    }

    /** Null intents are START_STICKY system restarts, not boot/force-stop hooks. */
    fun started(current: FlutterDownloadService, restarted: Boolean): Boolean {
        val restore = restarted || (!starting && latest.active == 0)
        service = current
        if (!wanted || pauseCommand != null || timedOut) {
            stopService()
            completeStarts()
            return false
        }
        try {
            current.show(if (latest.active > 0) latest else DownloadNotice.RECOVERING)
            heartbeat = SystemClock.elapsedRealtime()
            completeStarts()
            if (restore) {
                recover = true
                dispatchCommand()
            }
            return true
        } catch (error: Exception) {
            failStart(error)
            return false
        }
    }

    fun destroyed(current: FlutterDownloadService) {
        if (service === current) service = null
    }

    fun healthy(): Boolean = wanted && SystemClock.elapsedRealtime() - heartbeat < 120000

    fun pause(command: String = "pauseAll") {
        // Persist the user's stop before Dart acknowledges asynchronous cancel.
        wanted = false
        recover = false
        if (command == "serviceTimeout" || command == "downloadServiceStalled") timedOut = true
        pauseCommand = command
        commandGeneration++
        commandInFlight = false
        main.removeCallbacks(pauseTimeout)
        main.postDelayed(pauseTimeout, 10000)
        try {
            if (command != "pauseAll") stopService()
            else service?.show(DownloadNotice(1, "正在暂停下载…"), allowPause = false)
        } catch (error: Exception) {
            // Notification refresh is cosmetic; it must never prevent the
            // durable user stop from reaching the actual Dart transfer queue.
            stopService()
            report("download.pause_notice_failed", error)
        } finally {
            dispatchCommand()
        }
    }

    private fun dispatchCommand() {
        if (!ready || commandInFlight) return
        val command = pauseCommand ?: if (discardRecovery) "downloadDiscardRecovery"
            else if (recover) "downloadServiceRestarted" else return
        val generation = commandGeneration
        commandInFlight = true
        main.post {
            if (generation != commandGeneration) return@post
            send(command) { success ->
                if (generation != commandGeneration) return@send
                commandInFlight = false
                if (command == "downloadDiscardRecovery") {
                    discardRecovery = false
                    if (!success) report("download.recovery_clear_failed", IllegalStateException("旧下载恢复状态清理失败"))
                } else if (command == "downloadServiceRestarted") {
                    recover = false
                    if (!success) failStart(IllegalStateException("恢复后台下载失败"))
                } else {
                    main.removeCallbacks(pauseTimeout)
                    stopService()
                    if (success) pauseCommand = null
                    else report("download.pause_failed", IllegalStateException("后台下载暂停未完成"))
                }
                if (success) dispatchCommand()
            }
        }
    }

    private fun completeStarts(error: String? = null) {
        starting = false
        main.removeCallbacks(startTimeout)
        val pending = starts.toList()
        starts.clear()
        pending.forEach {
            if (error == null) it.success(null) else it.error("foreground", error, null)
        }
    }

    private fun failStart(error: Throwable) {
        wanted = false
        recover = false
        stopService()
        completeStarts("无法启动后台下载服务，请回到应用后重试")
        report("download.foreground_failed", error)
    }

    private fun stopService() {
        service?.finish()
        service = null
        context.stopService(Intent(context, FlutterDownloadService::class.java))
    }
}
