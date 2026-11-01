package com.asterlink.app
import android.app.Application
import com.asterlink.app.metrics.UsageMetrics
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor

/** Kept alive by the foreground service when the Activity is detached. */
class AsterLinkHost : Application(), DownloadServiceOwner, AppKeepAliveOwner, CastServiceOwner {
    override val downloadKeepAlive: DownloadKeepAlive get() = bridge.downloadKeepAlive
    override lateinit var appKeepAlive: AppKeepAlive
        private set
    lateinit var engine: FlutterEngine
        private set
    lateinit var bridge: NativeBridge
        private set
    lateinit var playback: PlaybackBridge
        private set
    override lateinit var casting: CastBridge
        private set
    lateinit var diagnostics: DiagnosticRecorder
        private set
    internal lateinit var analytics: UsageMetrics
        private set
    override fun onCreate() {
        super.onCreate()
        val process = if (android.os.Build.VERSION.SDK_INT >= 28) getProcessName() else
            (getSystemService(ACTIVITY_SERVICE) as android.app.ActivityManager).runningAppProcesses
                ?.firstOrNull { it.pid == android.os.Process.myPid() }?.processName.orEmpty()
        if (process.endsWith(":search")) {
            if (android.os.Build.VERSION.SDK_INT >= 28) android.webkit.WebView.setDataDirectorySuffix("search")
            return
        }
        diagnostics = DiagnosticRecorder(this)
        diagnostics.install()
        appKeepAlive = AppKeepAlive(this) { event, error -> diagnostics.record(event, error) }
        analytics = UsageMetrics(this, reportError = { name, error -> diagnostics.record(name, error) })
        analytics.start()
        engine = FlutterEngine(this)
        SearchBrowserBridge(this, engine)
        analytics.attach(engine.dartExecutor.binaryMessenger)
        bridge = NativeBridge(this, engine)
        playback = PlaybackBridge(this, engine)
        casting = CastBridge(this, engine) { event, error -> diagnostics.record(event, error) }
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
    }
}
