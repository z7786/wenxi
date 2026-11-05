package com.asterlink.app

import android.app.Activity
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Rational
import android.view.WindowManager
import androidx.annotation.RequiresApi
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.core.view.ViewCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

/** Playback-only window state; late calls from an old page cannot change a new page. */
class PlaybackBridge internal constructor(private val context: Context, private val channel: MethodChannel) {
    constructor(context: Context, engine: FlutterEngine) : this(context,
        MethodChannel(engine.dartExecutor.binaryMessenger, "com.asterlink.app/playback"))
    private var activity: Activity? = null
    private var session: String? = null
    private var video = false
    private var playing = false
    private var width = 16
    private var height = 9
    private var originalBrightness = -1f
    private var originalOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
    private var originalVolumeStream = Int.MIN_VALUE
    private var originalKeepScreen = false
    private var fullscreen = false
    private var controlsVisible = true
    private var originalStatusBar = true
    private var originalNavigationBar = true
    private var originalBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_DEFAULT
    private var desiredOrientation = "system"
    private var orientationLocked = false
    private val volume: PlaybackVolume = PlaybackVolume(context, changed = ::volumeChanged)
    private fun volumeChanged(value: Double) {
        emit("volume", mapOf("systemVolumeSupported" to volume.supported, "systemVolume" to value))
    }

    init { channel.setMethodCallHandler(::handle) }
    fun attach(current: Activity) {
        activity = current
        originalBrightness = current.window.attributes.screenBrightness
        originalOrientation = current.requestedOrientation
        originalVolumeStream = current.volumeControlStream
        originalKeepScreen = current.window.attributes.flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON != 0
        if (session != null) {
            current.volumeControlStream = AudioManager.STREAM_MUSIC
            volume.start(); updateWindow(); applyOrientation()
            emit("volume", mapOf("systemVolumeSupported" to volume.supported, "systemVolume" to volume.volume))
        }
    }
    fun detach(current: Activity) {
        if (activity === current) {
            restoreWindow()
            activity = null
        }
    }
    private fun emit(method: String, extra: Map<String, Any?>) {
        val token = session ?: return
        channel.invokeMethod(method, mapOf("session" to token) + extra)
    }
    fun pipChanged(current: Activity, active: Boolean) {
        if (activity === current) {
            if (!active) applyOrientation()
            emit("pip", mapOf("active" to active))
        }
    }
    fun stopped(current: Activity) {
        if (activity === current) emit("action", mapOf("action" to "hidden"))
    }
    fun paused(current: Activity) {
        if (activity !== current) return
        // PiP stays visible while Android reports the activity as paused.
        if (Build.VERSION.SDK_INT >= 26 && current.isInPictureInPictureMode) return
        emit("action", mapOf("action" to "hidden"))
    }
    fun windowFocused(current: Activity) {
        if (activity === current && session != null) {
            volume.refresh(); applySystemBars()
        }
    }
    fun volumeKey(current: Activity) {
        if (activity !== current || session == null) return
        current.window.decorView.post {
            if (activity === current && session != null) volume.refresh()
        }
    }
    fun action(token: String?, action: String?) {
        if (token != session || token == null || action !in setOf("rewind", "toggle", "forward")) return
        emit("action", mapOf("action" to action))
    }
    private fun supportsPip(): Boolean = video && Build.VERSION.SDK_INT >= 26 &&
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val token = call.argument<String>("session")
        if (token.isNullOrBlank()) { result.error("session", "播放会话无效", null); return }
        if (call.method != "begin" && token != session) { result.success(null); return }
        try {
            val current = activity
            when (call.method) {
                "begin" -> {
                    require(current != null)
                    if (session != null) restoreWindow()
                    session = token
                    video = call.argument<Boolean>("video") ?: false
                    playing = false
                    fullscreen = false
                    controlsVisible = true
                    desiredOrientation = "system"
                    orientationLocked = false
                    width = 16; height = 9
                    originalBrightness = current.window.attributes.screenBrightness
                    originalOrientation = current.requestedOrientation
                    originalVolumeStream = current.volumeControlStream
                    originalKeepScreen = current.window.attributes.flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON != 0
                    val insets = ViewCompat.getRootWindowInsets(current.window.decorView)
                    originalStatusBar = insets?.isVisible(WindowInsetsCompat.Type.statusBars()) ?: true
                    originalNavigationBar = insets?.isVisible(WindowInsetsCompat.Type.navigationBars()) ?: true
                    originalBarsBehavior = WindowInsetsControllerCompat(current.window, current.window.decorView).systemBarsBehavior
                    current.volumeControlStream = AudioManager.STREAM_MUSIC
                    volume.start()
                    val brightness = if (originalBrightness >= 0) originalBrightness
                        else runCatching { Settings.System.getInt(context.contentResolver, Settings.System.SCREEN_BRIGHTNESS, 128) / 255f }
                            .getOrDefault(.5f)
                    result.success(mapOf("pip" to supportsPip(), "brightness" to brightness.toDouble(),
                        "systemVolumeSupported" to volume.supported, "systemVolume" to volume.volume))
                }
                "state" -> {
                    playing = call.argument<Boolean>("playing") ?: false
                    width = (call.argument<Number>("width")?.toInt() ?: width).coerceAtLeast(1)
                    height = (call.argument<Number>("height")?.toInt() ?: height).coerceAtLeast(1)
                    call.argument<String>("orientation")?.takeIf { it in setOf("system", "portrait", "landscape") }
                        ?.let { desiredOrientation = it }
                    orientationLocked = call.argument<Boolean>("locked") ?: false
                    controlsVisible = call.argument<Boolean>("controlsVisible") ?: true
                    applyOrientation()
                    updateWindow()
                    result.success(null)
                }
                "brightness" -> {
                    require(current != null)
                    val value = call.argument<Number>("value")?.toFloat() ?: originalBrightness
                    require(value.isFinite())
                    current.window.attributes = current.window.attributes.apply { screenBrightness = value.coerceIn(0f, 1f) }
                    result.success(null)
                }
                "volume" -> {
                    val value = call.argument<Number>("value")?.toDouble() ?: Double.NaN
                    val actual = volume.setVolume(value)
                    result.success(mapOf("systemVolumeSupported" to volume.supported, "systemVolume" to actual))
                }
                "fullscreen" -> {
                    require(current != null)
                    fullscreen = call.argument<Boolean>("enabled") ?: false
                    applyOrientation()
                    applySystemBars()
                    result.success(null)
                }
                "enterPip" -> {
                    result.success(if (current != null && supportsPip() && Build.VERSION.SDK_INT >= 26)
                        current.enterPictureInPictureMode(parameters()) else false)
                }
                "isPip" -> result.success(current != null && Build.VERSION.SDK_INT >= 26 && current.isInPictureInPictureMode)
                "end" -> {
                    restoreWindow()
                    session = null; video = false; playing = false; fullscreen = false
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            (context.applicationContext as? AsterLinkHost)?.diagnostics?.record("playback.${call.method}", error)
            result.error("playback", "系统播放控制未能完成，请重试", null)
        }
    }
    private fun updateWindow() {
        val current = activity ?: return
        applySystemBars()
        if (playing && video) current.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else if (!originalKeepScreen) current.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (supportsPip() && Build.VERSION.SDK_INT >= 26) {
            try { current.setPictureInPictureParams(parameters()) } catch (_: Exception) { /* capability can change */ }
        }
    }
    private fun applySystemBars() {
        val current = activity ?: return
        if (session == null || (Build.VERSION.SDK_INT >= 26 && current.isInPictureInPictureMode)) return
        val controller = WindowInsetsControllerCompat(current.window, current.window.decorView)
        controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        if (video && (fullscreen || !controlsVisible || orientationLocked)) {
            controller.hide(WindowInsetsCompat.Type.systemBars())
        } else {
            controller.show(WindowInsetsCompat.Type.systemBars())
        }
    }
    private fun applyOrientation() {
        val current = activity ?: return
        if (session == null || (Build.VERSION.SDK_INT >= 26 && current.isInPictureInPictureMode)) return
        val requested = when {
            orientationLocked -> ActivityInfo.SCREEN_ORIENTATION_LOCKED
            !video -> originalOrientation
            desiredOrientation == "landscape" -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            desiredOrientation == "portrait" -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
            else -> originalOrientation
        }
        if (current.requestedOrientation != requested) current.requestedOrientation = requested
    }
    @RequiresApi(26)
    private fun parameters(): PictureInPictureParams {
        check(Build.VERSION.SDK_INT >= 26)
        val ratio = (width.toDouble() / height).coerceIn(1.0 / 2.39, 2.39)
        val actions = listOf(
            remoteAction("rewind", "后退 15 秒", android.R.drawable.ic_media_rew, 7401),
            remoteAction("toggle", if (playing) "暂停" else "播放",
                if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play, 7402),
            remoteAction("forward", "前进 15 秒", android.R.drawable.ic_media_ff, 7403))
        return PictureInPictureParams.Builder().setAspectRatio(Rational((ratio * 10000).roundToInt(), 10000))
            .setActions(actions).build()
    }
    @RequiresApi(26)
    private fun remoteAction(action: String, title: String, resource: Int, code: Int): RemoteAction {
        check(Build.VERSION.SDK_INT >= 26)
        val intent = Intent(context, PlaybackActionReceiver::class.java)
            .setData(Uri.parse("asterlink://playback/$session/$action"))
            .putExtra("session", session).putExtra("action", action)
        val pending = PendingIntent.getBroadcast(context, code, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return RemoteAction(Icon.createWithResource(context, resource), title, title, pending)
    }
    private fun restoreWindow() {
        volume.stop()
        val current = activity ?: return
        current.window.attributes = current.window.attributes.apply { screenBrightness = originalBrightness }
        current.requestedOrientation = originalOrientation
        current.volumeControlStream = originalVolumeStream
        if (originalKeepScreen) current.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else current.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val controller = WindowInsetsControllerCompat(current.window, current.window.decorView)
        controller.systemBarsBehavior = originalBarsBehavior
        if (originalStatusBar) controller.show(WindowInsetsCompat.Type.statusBars())
        else controller.hide(WindowInsetsCompat.Type.statusBars())
        if (originalNavigationBar) controller.show(WindowInsetsCompat.Type.navigationBars())
        else controller.hide(WindowInsetsCompat.Type.navigationBars())
    }
}

class PlaybackActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        (context.applicationContext as? AsterLinkHost)?.playback?.action(
            intent.getStringExtra("session"), intent.getStringExtra("action"))
    }
}
