package com.asterlink.app

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.os.Debug
import android.os.Process
import android.os.SystemClock
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicBoolean

/** Only this app's private diagnostic directory is read or written. */
class DiagnosticRecorder(private val context: Context, private val now: () -> Long = System::currentTimeMillis) {
    private val root = File(context.noBackupFilesDir, "diagnostics_native")
    private val preferences = context.getSharedPreferences("asterlink_diagnostics", Context.MODE_PRIVATE)
    private val recording = AtomicBoolean(preferences.getBoolean("enabled", true))
    private val handlingCrash = AtomicBoolean(false)
    private val lock = Any()
    private val startedAt = now()
    private val recent = linkedMapOf<String, Long>()
    private var suppressed = 0L
    private var installed = false
    val enabled: Boolean get() = recording.get()

    companion object {
        const val FILE_LIMIT = 256 * 1024
        const val FILE_COUNT = 8
        const val RETENTION_MS = 7L * 24 * 60 * 60 * 1000
        private val filePattern = Regex("native-[0-9]+-[0-9]+\\.json")
        private val url = Regex("(?i)\\b(?:https?|wss?|content|file|magnet|data):[^\\s<>\"']+")
        private val header = Regex("(?i)(?:set-cookie|cookie|authorization|proxy-authorization)\\s*[=:]\\s*[^\\r\\n]+")
        private val pair = Regex("(?i)((?:[\\w.-]*(?:token|secret|password|passwd|passcode|credential|skey|signature|cookie)[\\w.-]*|BDUSS|STOKEN|__puus|__pus|pwd|access_code|提取码|访问码|密码|口令)[\"']?\\s*[=:：]\\s*)(?:\"(?:\\\\.|[^\"\\\\\\r\\n])*\"|'(?:\\\\.|[^'\\\\\\r\\n])*'|[^\\s,;&}\\]\\r\\n]+)")

        fun redact(value: String, limit: Int = 16000): String {
            var text = value.take(64000)
                .replace(Regex("[\\x00-\\x08\\x0b\\x0c\\x0e-\\x1f\\x7f]"), "")
                .replace(header, "凭据: [已隐藏]")
                .replace(url, "[链接已隐藏]")
                .replace(pair) { "${it.groupValues[1]}[已隐藏]" }
                .replace(Regex("((?:提取码|访问码|密码|口令)\\s+)[A-Za-z0-9_-]+")) { "${it.groupValues[1]}[已隐藏]" }
                .replace(Regex("(?i)\\b(?:Bearer|Basic)\\s+[A-Za-z0-9+/=_-]+"), "[已隐藏]")
                .replace(Regex("\\b[A-Za-z]:[\\\\/][^\\r\\n\"'<>]*"), "[本地路径已隐藏]")
                .replace(Regex("\\\\\\\\[^\\r\\n\"'<> ]+\\\\[^\\r\\n\"'<>]*"), "[本地路径已隐藏]")
                .replace(Regex("/(?:storage|sdcard|data|home|Users|tmp|mnt|private|var|Volumes)/[^\\r\\n\"'<>]*"), "[本地路径已隐藏]")
                .replace(Regex("\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\b"), "[邮箱已隐藏]")
                .replace(Regex("\\b1[3-9][0-9]{9}\\b"), "[手机号已隐藏]")
                .replace(Regex("\\b(?:[0-9]{1,3}\\.){3}[0-9]{1,3}\\b"), "[IP 已隐藏]")
            if (text.length > limit) text = text.take(limit) + "…[已截断]"
            return text
        }

        fun reasonName(reason: Int): String = when (reason) {
            ApplicationExitInfo.REASON_CRASH -> "java_crash"
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "native_crash"
            ApplicationExitInfo.REASON_ANR -> "anr"
            ApplicationExitInfo.REASON_LOW_MEMORY -> "low_memory"
            ApplicationExitInfo.REASON_USER_REQUESTED -> "user_requested"
            ApplicationExitInfo.REASON_USER_STOPPED -> "user_stopped"
            ApplicationExitInfo.REASON_SIGNALED -> "signal"
            ApplicationExitInfo.REASON_EXIT_SELF -> "self_exit"
            ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "initialization_failure"
            else -> "system_exit_$reason"
        }
    }

    fun install() {
        if (installed) return
        installed = true
        runCatching { root.mkdirs(); prune() }
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            if (handlingCrash.compareAndSet(false, true)) {
                record("android.uncaught", error, true, thread.name)
            }
            // Preserve Android's normal crash handling; never hide a fatal error.
            if (previous != null) previous.uncaughtException(thread, error)
            else { Process.killProcess(Process.myPid()); kotlin.system.exitProcess(10) }
        }
    }

    fun record(event: String, error: Throwable, fatal: Boolean = false, thread: String = Thread.currentThread().name) {
        if (!recording.get()) return
        runCatching {
            val cleanEvent = redact(event, 120)
            val fingerprint = "$cleanEvent|${error.javaClass.name}|${redact(error.message.orEmpty(), 300)}"
            synchronized(lock) {
                if (!recording.get()) return
                val last = recent[fingerprint]
                if (!fatal && last != null && now() - last in 0L until 30000L) {
                    suppressed++
                    return
                }
                recent[fingerprint] = now()
                while (recent.size > 64) recent.remove(recent.keys.first())
            }
            val causes = mutableListOf<Map<String, Any>>()
            val seen = java.util.Collections.newSetFromMap(java.util.IdentityHashMap<Throwable, Boolean>())
            var framesLeft = 100
            var current: Throwable? = error
            repeat(6) {
                val item = current ?: return@repeat
                if (!seen.add(item)) return@repeat
                val frames = item.stackTrace.take(minOf(50, framesLeft))
                framesLeft -= frames.size
                causes.add(mapOf("type" to redact(item.javaClass.name, 160),
                    "message" to redact(item.message.orEmpty(), 1500),
                    "stack" to frames.map { frame -> redact(frame.toString(), 300) },
                    "framesOmitted" to maxOf(0, item.stackTrace.size - frames.size)))
                current = item.cause?.takeUnless { it === item }
            }
            val record = JSONObject(mapOf(
                "time" to now(), "startedAt" to startedAt,
                "pid" to Process.myPid(), "version" to version(),
                "level" to if (fatal) "fatal" else "error", "event" to cleanEvent,
                "thread" to redact(thread, 120), "causes" to causes)).toString()
            synchronized(lock) {
                if (!recording.get()) return
                check(root.mkdirs() || root.isDirectory)
                val file = File(root, "native-${now()}-${System.nanoTime().and(Long.MAX_VALUE)}.json")
                val bytes = record.toByteArray(Charsets.UTF_8)
                if (bytes.size <= FILE_LIMIT) {
                    FileOutputStream(file).use { output -> output.write(bytes); if (fatal) output.fd.sync() }
                }
                prune()
            }
        }
    }

    private fun files() = root.listFiles()?.filter {
        filePattern.matches(it.name) && it.isFile && it.canonicalFile.parentFile == root.canonicalFile
    }?.sortedBy { it.lastModified() }.orEmpty()

    private fun prune() {
        val all = files().toMutableList()
        for (file in all.toList()) {
            if (now() - file.lastModified() > RETENTION_MS || all.size > FILE_COUNT) {
                if (file.delete()) all.remove(file)
            }
        }
    }

    private fun version(): String = runCatching {
        @Suppress("DEPRECATION")
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        @Suppress("DEPRECATION")
        "${info.versionName}+${if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()}"
    }.getOrDefault("unknown")

    /** Numeric process counters only, called on the bridge's worker thread. */
    fun memorySnapshot(): Map<String, Any> {
        if (!recording.get()) return emptyMap()
        val started = SystemClock.elapsedRealtime()
        val data = mutableMapOf<String, Any>(
            "sampleElapsedMs" to SystemClock.elapsedRealtime(), "pid" to Process.myPid(),
        )
        runCatching {
            val memory = Debug.MemoryInfo()
            Debug.getMemoryInfo(memory)
            data["pssKb"] = memory.totalPss
            data["privateDirtyKb"] = memory.totalPrivateDirty
            data["nativeHeapAllocatedBytes"] = Debug.getNativeHeapAllocatedSize()
            val runtime = Runtime.getRuntime()
            data["javaHeapUsedBytes"] = runtime.totalMemory() - runtime.freeMemory()
            if (Build.VERSION.SDK_INT >= 23) {
                for ((key, name) in mapOf(
                    "summary.java-heap" to "javaHeapPrivateKb",
                    "summary.native-heap" to "nativeHeapPrivateKb",
                    "summary.graphics" to "graphicsPrivateKb",
                    "summary.stack" to "stackPrivateKb",
                    "summary.total-swap" to "swapKb",
                )) memory.getMemoryStat(key)?.toLongOrNull()?.let { data[name] = it }
            }
        }.onFailure { data["memoryInfoUnavailable"] = true }
        runCatching {
            // A fixed kernel status file; its contents are never exported.
            val status = File("/proc/self/status").inputStream().use {
                it.readNBytesCompat(16 * 1024).toString(Charsets.US_ASCII)
            }
            for ((key, name) in mapOf("VmRSS" to "rssKb", "Threads" to "threadCount")) {
                Regex("(?m)^$key:\\s+(\\d+)").find(status)?.groupValues?.get(1)?.toLongOrNull()
                    ?.let { data[name] = it }
            }
        }
        data["sampleCostMs"] = SystemClock.elapsedRealtime() - started
        return if (recording.get()) data else emptyMap()
    }

    fun snapshot(): Map<String, Any> {
        val result = mutableMapOf<String, Any>(
            "enabled" to recording.get(), "api" to Build.VERSION.SDK_INT,
            "manufacturer" to Build.MANUFACTURER, "model" to Build.MODEL,
            "android" to Build.VERSION.RELEASE, "abis" to Build.SUPPORTED_ABIS.toList(),
            "version" to version(), "pid" to Process.myPid(),
            "exitHistorySupported" to (Build.VERSION.SDK_INT >= 30))
        synchronized(lock) {
            result["suppressedRepeats"] = suppressed
            runCatching { prune() }
            result["reports"] = files().takeLast(FILE_COUNT).mapNotNull { file ->
                runCatching {
                    val data = file.inputStream().use { it.readNBytesCompat(FILE_LIMIT) }.toString(Charsets.UTF_8)
                    // Each field was redacted before JSON serialization. Redacting
                    // the serialized JSON itself could corrupt quoted stack strings.
                    mapOf("name" to file.name, "content" to data)
                }.getOrNull()
            }
        }
        if (Build.VERSION.SDK_INT >= 30 && recording.get()) {
            try {
                var nativeTraces = 0
                val cutoff = maxOf(preferences.getLong("clearedAt", 0), now() - RETENTION_MS)
                val activity = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                result["exits"] = activity.getHistoricalProcessExitReasons(context.packageName, 0, 12)
                    .filter { it.timestamp > cutoff }.map { exit ->
                        val data = mutableMapOf<String, Any>("time" to exit.timestamp,
                            "reason" to reasonName(exit.reason), "reasonCode" to exit.reason,
                            "status" to exit.status, "importance" to exit.importance,
                            "pssKb" to exit.pss, "rssKb" to exit.rss,
                            "process" to redact(exit.processName),
                            "description" to redact(exit.description.orEmpty(), 3000))
                        if (exit.reason == ApplicationExitInfo.REASON_ANR) {
                            runCatching {
                                exit.traceInputStream?.use { stream ->
                                    data["trace"] = redact(stream.readNBytesCompat(64 * 1024).toString(Charsets.UTF_8), 64 * 1024)
                                }
                            }.onFailure { data["traceUnavailable"] = true }
                        } else if (exit.reason == ApplicationExitInfo.REASON_CRASH_NATIVE) {
                            if (Build.VERSION.SDK_INT >= 31 && nativeTraces++ < 2) {
                                runCatching {
                                    data.putAll(NativeCrashTrace.extract { exit.traceInputStream })
                                }.onFailure {
                                    data["traceUnavailable"] = true
                                    data["traceNote"] = "原生堆栈无法安全解析或超出读取上限；保留退出原因"
                                }
                            } else {
                                data["traceUnavailable"] = true
                                data["traceNote"] = if (Build.VERSION.SDK_INT < 31)
                                    "Android 12 以下无法读取原生崩溃堆栈" else "仅提取最近两次原生崩溃的堆栈"
                            }
                        }
                        data
                    }
            } catch (_: Exception) { result["exitHistoryUnavailable"] = true }
        }
        return result
    }

    fun setEnabled(enabled: Boolean) {
        synchronized(lock) {
            val edit = preferences.edit().putBoolean("enabled", enabled)
            // Android itself continues to record exits. Exclude any recorded while
            // this feature was off when the user later turns it back on.
            if (enabled && !recording.get()) edit.putLong("clearedAt", now())
            check(edit.commit())
            recording.set(enabled)
        }
    }

    fun clear() {
        synchronized(lock) {
            for (file in files()) check(file.delete() || !file.exists())
            check(preferences.edit().putLong("clearedAt", now()).commit())
            recent.clear()
            suppressed = 0
        }
    }

    private fun java.io.InputStream.readNBytesCompat(limit: Int): ByteArray {
        val output = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        while (output.size() < limit) {
            val count = read(buffer, 0, minOf(buffer.size, limit - output.size()))
            if (count <= 0) break
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }
}
