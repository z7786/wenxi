package com.asterlink.app

import android.app.ApplicationExitInfo
import android.app.ActivityManager
import android.content.Context
import java.io.File
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import org.robolectric.util.ReflectionHelpers

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class DiagnosticRecorderTest {
    private lateinit var context: Context
    private lateinit var recorder: DiagnosticRecorder
    private lateinit var root: File

    @Before fun setup() {
        context = RuntimeEnvironment.getApplication()
        context.getSharedPreferences("asterlink_diagnostics", Context.MODE_PRIVATE).edit().clear().commit()
        root = File(context.noBackupFilesDir, "diagnostics_native")
        root.mkdirs()
        root.listFiles()?.forEach { if (it.isFile) it.delete() }
        recorder = DiagnosticRecorder(context)
    }

    private fun reports(target: DiagnosticRecorder = recorder): List<JSONObject> {
        @Suppress("UNCHECKED_CAST")
        val data = target.snapshot()["reports"] as List<Map<String, String>>
        return data.map { JSONObject(it.getValue("content")) }
    }

    @Test fun uncaughtHandlerFlushesFatalReportAndDelegatesOriginalError() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        val error = IllegalStateException("Cookie: private-cookie")
        var received: Throwable? = null
        var receivedThread: Thread? = null
        Thread.setDefaultUncaughtExceptionHandler { thread, thrown -> receivedThread = thread; received = thrown }
        try {
            recorder.install()
            val handler = Thread.getDefaultUncaughtExceptionHandler()
            recorder.install()
            assertSame(handler, Thread.getDefaultUncaughtExceptionHandler())
            handler!!.uncaughtException(Thread.currentThread(), error)
            assertSame(error, received)
            assertSame(Thread.currentThread(), receivedThread)
            val recorded = reports(DiagnosticRecorder(context)).single()
            assertEquals("android.uncaught", recorded.getString("event"))
            assertEquals("fatal", recorded.getString("level"))
            assertTrue(recorded.toString().contains("IllegalStateException"))
            assertFalse(recorded.toString().contains("private-cookie"))
        } finally { Thread.setDefaultUncaughtExceptionHandler(previous) }
    }

    @Test fun redactionCoversEscapedCredentialsLinksPathsAndExtractionCodes() {
        val value = listOf(
            "Cookie: __puus=private-cookie",
            """{"token":"private-start\"private-end", "pwd":"private-code"}""",
            "提取码 abcd 访问码：efgh",
            "https://example.invalid/private-link?token=private-token",
            "content://provider/private-document",
            """D:\private-folder\file.mkv""",
            """\\private-server\share\file.mkv""",
            "private-user@example.invalid 13800138000 192.168.2.99"
        ).joinToString("\n")
        val clean = DiagnosticRecorder.redact(value)
        listOf("private-", "abcd", "efgh", "13800138000", "192.168.2.99").forEach {
            assertFalse(it, clean.contains(it))
        }
    }

    @Test fun reportRotationAndAgeLimitDoNotRemoveUnrelatedFiles() {
        val keep = File(root, "keep.txt").apply { writeText("keep") }
        val old = File(root, "native-1-1.json").apply {
            writeText("{}")
            setLastModified(System.currentTimeMillis() - DiagnosticRecorder.RETENTION_MS - 1000)
        }
        repeat(14) { recorder.record("failure.$it", IllegalStateException("fixture $it")) }
        assertFalse(old.exists())
        assertEquals(DiagnosticRecorder.FILE_COUNT, reports().size)
        assertTrue(root.listFiles()!!.filter { it.name.startsWith("native-") }.sumOf { it.length() } <= DiagnosticRecorder.FILE_LIMIT.toLong() * DiagnosticRecorder.FILE_COUNT)
        recorder.clear()
        assertTrue(reports().isEmpty())
        assertEquals("keep", keep.readText())
    }

    @Test fun disabledPreferencePersistsAndClearResetsOnlyDiagnosticHistory() {
        recorder.record("before.disable", IllegalStateException("fixture"))
        recorder.setEnabled(false)
        val reopened = DiagnosticRecorder(context)
        assertFalse(reopened.enabled)
        reopened.record("disabled.crash", IllegalStateException("fixture"), true)
        assertEquals(1, reports(reopened).size)
        reopened.clear()
        assertTrue(reports(reopened).isEmpty())
        reopened.setEnabled(true)
        reopened.record("enabled.crash", IllegalStateException("fixture"), true)
        assertEquals("enabled.crash", reports(reopened).single().getString("event"))
        assertTrue(context.getSharedPreferences("asterlink_diagnostics", Context.MODE_PRIVATE).getLong("clearedAt", 0) > 0)
    }

    @Test fun duplicateErrorsAreSuppressedButFatalReportsStillSurvive() {
        repeat(100) { recorder.record("bridge.error", IllegalStateException("fixture")) }
        assertEquals(1, reports().size)
        assertEquals(99L, recorder.snapshot()["suppressedRepeats"])
        recorder.record("bridge.error", IllegalStateException("fixture"), true)
        assertEquals(2, reports().size)
    }

    @Test fun largeCauseChainIsBoundedAndProducesValidJson() {
        var error: Throwable = IllegalStateException("密码=private-password")
        repeat(12) {
            error = IllegalStateException("界".repeat(50000), error).apply {
                stackTrace = Array(200) { StackTraceElement("Class" + "界".repeat(500), "method", "Source.kt", 10) }
            }
        }
        recorder.record("android.uncaught", error, true)
        val report = reports().single()
        assertEquals(6, report.getJSONArray("causes").length())
        assertTrue(report.toString().toByteArray().size <= DiagnosticRecorder.FILE_LIMIT)
        assertFalse(report.toString().contains("private-password"))
    }

    @Test fun unwritableDirectoryDoesNotMaskOriginalCrash() {
        assertTrue(root.delete())
        root.writeText("blocked")
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        var delegated = false
        Thread.setDefaultUncaughtExceptionHandler { _, _ -> delegated = true }
        try {
            recorder.install()
            Thread.getDefaultUncaughtExceptionHandler()!!.uncaughtException(Thread.currentThread(), IllegalStateException("fixture"))
            assertTrue(delegated)
        } finally {
            Thread.setDefaultUncaughtExceptionHandler(previous)
            root.delete()
        }
    }

    @Test fun exitReasonsDistinguishCrashesFromSystemAndUserExits() {
        assertEquals("java_crash", DiagnosticRecorder.reasonName(ApplicationExitInfo.REASON_CRASH))
        assertEquals("native_crash", DiagnosticRecorder.reasonName(ApplicationExitInfo.REASON_CRASH_NATIVE))
        assertEquals("anr", DiagnosticRecorder.reasonName(ApplicationExitInfo.REASON_ANR))
        assertEquals("low_memory", DiagnosticRecorder.reasonName(ApplicationExitInfo.REASON_LOW_MEMORY))
        assertEquals("user_requested", DiagnosticRecorder.reasonName(ApplicationExitInfo.REASON_USER_REQUESTED))
        assertEquals(false, recorder.snapshot()["exitHistorySupported"])
    }

    @Test fun memoryCountersAreNumericAndHonorOptOut() {
        val data = recorder.memorySnapshot()
        assertTrue(data.containsKey("pid"))
        assertTrue(data.containsKey("pssKb"))
        assertTrue(data.containsKey("nativeHeapAllocatedBytes"))
        assertTrue(data.values.all { it is Number || it is Boolean })
        recorder.setEnabled(false)
        assertTrue(recorder.memorySnapshot().isEmpty())
    }

    @Test @Config(sdk = [30]) fun systemExitHistoryHonorsRetentionClearAndOptOut() {
        val activity = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val shadow = Shadows.shadowOf(activity)
        val now = System.currentTimeMillis()
        fun add(reason: Int, stamp: Long) {
            val exit = ReflectionHelpers.newInstance(ApplicationExitInfo::class.java)
            ReflectionHelpers.setField(exit, "mReason", reason)
            ReflectionHelpers.setField(exit, "mTimestamp", stamp)
            ReflectionHelpers.setField(exit, "mProcessName", context.packageName)
            ReflectionHelpers.setField(exit, "mDescription", "Cookie: private-value")
            shadow.addApplicationExitInfo(exit)
        }
        add(ApplicationExitInfo.REASON_CRASH, now - DiagnosticRecorder.RETENTION_MS - 1000)
        add(ApplicationExitInfo.REASON_LOW_MEMORY, now - 5000)
        add(ApplicationExitInfo.REASON_CRASH_NATIVE, now - 4000)
        add(ApplicationExitInfo.REASON_ANR, now - 3000)
        val first = JSONObject(recorder.snapshot())
        assertTrue(first.getBoolean("exitHistorySupported"))
        assertEquals(3, first.getJSONArray("exits").length())
        assertTrue(first.toString().contains("native_crash"))
        assertTrue(first.toString().contains("low_memory"))
        assertFalse(first.toString().contains("private-value"))
        recorder.setEnabled(false)
        assertFalse(recorder.snapshot().containsKey("exits"))
        recorder.setEnabled(true)
        assertEquals(0, JSONObject(recorder.snapshot()).getJSONArray("exits").length())
        val later = DiagnosticRecorder(context) { now + 10000 }
        add(ApplicationExitInfo.REASON_CRASH, now + 1000)
        assertEquals(1, JSONObject(later.snapshot()).getJSONArray("exits").length())
        later.clear()
        assertEquals(0, JSONObject(later.snapshot()).getJSONArray("exits").length())
    }
}
