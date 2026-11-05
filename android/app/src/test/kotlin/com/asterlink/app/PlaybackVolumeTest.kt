package com.asterlink.app

import android.content.Context
import android.media.AudioManager
import android.os.Looper
import android.provider.Settings
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class PlaybackVolumeTest {
    private lateinit var context: Context
    private lateinit var audio: AudioManager
    private lateinit var volume: PlaybackVolume
    private val changes = mutableListOf<Double>()

    @Before fun setup() {
        context = RuntimeEnvironment.getApplication()
        audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audio.setStreamVolume(AudioManager.STREAM_MUSIC, 6, 0)
        audio.setStreamVolume(AudioManager.STREAM_RING, 3, 0)
        changes.clear()
        volume = PlaybackVolume(context) { changes.add(it) }
    }

    @After fun cleanup() { volume.stop() }

    @Test fun playbackStartAndStopLeaveTheCurrentSystemVolumeAlone() {
        val initial = audio.getStreamVolume(AudioManager.STREAM_MUSIC)
        volume.start()
        volume.start()
        assertEquals(initial, audio.getStreamVolume(AudioManager.STREAM_MUSIC))
        assertTrue(changes.isEmpty())
        val actual = volume.setVolume(73.0)
        val index = audio.getStreamVolume(AudioManager.STREAM_MUSIC)
        val maximum = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        assertEquals(index.toDouble() / maximum * 100, actual, .001)
        assertEquals(actual, changes.single(), .001)
        assertEquals(3, audio.getStreamVolume(AudioManager.STREAM_RING))
        volume.stop()
        assertEquals(index, audio.getStreamVolume(AudioManager.STREAM_MUSIC))
    }

    @Test fun volumeKeysAndSettingsRefreshOnceAndStopDropsLateCallbacks() {
        volume.start()
        audio.setStreamVolume(AudioManager.STREAM_MUSIC, 4, 0)
        context.contentResolver.notifyChange(Settings.System.CONTENT_URI, null)
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(1, changes.size)
        volume.refresh()
        assertEquals(1, changes.size)
        volume.stop()
        audio.setStreamVolume(AudioManager.STREAM_MUSIC, 2, 0)
        context.contentResolver.notifyChange(Settings.System.CONTENT_URI, null)
        shadowOf(Looper.getMainLooper()).idle()
        volume.refresh()
        assertEquals(1, changes.size)
    }

    @Test fun muteAndMaximumUseTheSystemMediaStreamBounds() {
        volume.start()
        assertEquals(0.0, volume.setVolume(-20.0), .001)
        assertEquals(100.0, volume.setVolume(150.0), .001)
        assertEquals(audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC), audio.getStreamVolume(AudioManager.STREAM_MUSIC))
    }

    @Test fun unavailableSettingsObserverStillAllowsSystemVolumeAndPolling() {
        volume = PlaybackVolume(context, registerObserver = { throw SecurityException("observer unavailable") }) { changes.add(it) }
        volume.start()
        assertTrue(volume.supported)
        assertEquals(100.0, volume.setVolume(100.0), .001)
        assertEquals(audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC), audio.getStreamVolume(AudioManager.STREAM_MUSIC))
        changes.clear()
        audio.setStreamVolume(AudioManager.STREAM_MUSIC, 2, 0)
        shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(500))
        assertEquals(listOf(volume.volume), changes)
        volume.stop()
        changes.clear()
        audio.setStreamVolume(AudioManager.STREAM_MUSIC, 5, 0)
        shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(1))
        assertTrue(changes.isEmpty())
    }
}
