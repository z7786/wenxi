package com.asterlink.app

import android.content.Context
import android.database.ContentObserver
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import kotlin.math.roundToInt

/** Media stream volume only; starting or closing playback never changes it. */
class PlaybackVolume(
    private val context: Context,
    private val registerObserver: (ContentObserver) -> Unit = {
        context.contentResolver.registerContentObserver(Settings.System.CONTENT_URI, true, it)
    },
    private val changed: (Double) -> Unit,
) {
    private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var observing = false
    private var registered = false
    private val handler = Handler(Looper.getMainLooper())
    private val poll = object : Runnable {
        override fun run() {
            if (!observing) return
            refresh()
            handler.postDelayed(this, 500)
        }
    }
    private var lastVolume = Double.NaN
    private val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) { refresh() }
    }

    val supported: Boolean get() = !audio.isVolumeFixed && audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC) > 0
    val volume: Double get() {
        val maximum = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (maximum <= 0) return 100.0
        return (audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / maximum * 100).coerceIn(0.0, 100.0)
    }

    fun start() {
        if (observing) return
        lastVolume = volume
        observing = true
        // Some device settings providers reject observers or omit media-volume notifications.
        registered = runCatching { registerObserver(observer) }.isSuccess
        handler.postDelayed(poll, 500)
    }

    fun refresh() {
        if (!observing) return
        val current = volume
        if (current == lastVolume) return
        lastVolume = current
        changed(current)
    }

    fun setVolume(value: Double): Double {
        require(value.isFinite() && supported)
        val stream = AudioManager.STREAM_MUSIC
        val maximum = audio.getStreamMaxVolume(stream)
        val minimum = if (Build.VERSION.SDK_INT >= 28) audio.getStreamMinVolume(stream) else 0
        val index = (value.coerceIn(0.0, 100.0) * maximum / 100).roundToInt().coerceIn(minimum, maximum)
        audio.setStreamVolume(stream, index, 0)
        // Let Android explain a safe-volume limit instead of claiming the requested level succeeded.
        if (audio.getStreamVolume(stream) != index) {
            audio.setStreamVolume(stream, index, AudioManager.FLAG_SHOW_UI)
        }
        refresh()
        return volume
    }

    fun stop() {
        if (!observing) return
        observing = false
        handler.removeCallbacks(poll)
        if (registered) runCatching { context.contentResolver.unregisterContentObserver(observer) }
        registered = false
    }
}
