package com.asterlink.app

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Context
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Rect
import android.view.View
import android.view.ViewGroup
import io.flutter.embedding.android.FlutterSurfaceView
import androidx.core.graphics.Insets as CompatInsets
import androidx.core.view.DisplayCutoutCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.nio.ByteBuffer

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE, shadows = [PlaybackTestSurfaceView::class])
class PlaybackLifecycleTest {
    private class Messenger : BinaryMessenger {
        val sent = mutableListOf<MethodCall>()
        var handler: BinaryMessenger.BinaryMessageHandler? = null
        override fun send(channel: String, message: ByteBuffer?) {
            send(channel, message, null)
        }
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            message!!.flip()
            sent.add(StandardMethodCodec.INSTANCE.decodeMethodCall(message))
            callback?.reply(StandardMethodCodec.INSTANCE.encodeSuccessEnvelope(null))
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            this.handler = handler
        }
        fun call(method: String, arguments: Map<String, Any?>): Any? {
            val message = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method, arguments))
            message.flip()
            var value: Any? = null
            handler!!.onMessage(message) { response ->
                response!!.flip()
                value = StandardMethodCodec.INSTANCE.decodeEnvelope(response)
            }
            return value
        }
    }

    private lateinit var activity: Activity
    private lateinit var bridge: PlaybackBridge
    private lateinit var messenger: Messenger
    private var windowInsets: WindowInsetsCompat? = null
    private val frameRates = mutableListOf<Float>()

    @Before fun setup() {
        val context: Context = RuntimeEnvironment.getApplication()
        activity = Robolectric.buildActivity(Activity::class.java).setup().visible().get()
        messenger = Messenger()
        bridge = PlaybackBridge(context, MethodChannel(messenger, "com.asterlink.app/playback"),
            rootInsets = { windowInsets ?: ViewCompat.getRootWindowInsets(it) },
            displayCadence = PlaybackFrameRate { _, rate -> frameRates.add(rate) })
        bridge.attach(activity)
        messenger.call("begin", mapOf("session" to "test-player", "video" to true))
        messenger.sent.clear()
    }

    @Test fun castingKeepsDisplayAwakeAcrossPlayerEndAndReleasesAfterStop() {
        fun awake() = activity.window.attributes.flags and android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON != 0
        bridge.setCasting(true)
        messenger.call("state", mapOf("session" to "test-player", "playing" to false))
        assertTrue(awake())
        messenger.call("end", mapOf("session" to "test-player"))
        assertTrue(awake())
        bridge.setCasting(false)
        assertFalse(awake())
        messenger.call("begin", mapOf("session" to "other", "video" to true))
        bridge.setCasting(true)
        messenger.call("state", mapOf("session" to "other", "playing" to true))
        bridge.setCasting(false)
        assertTrue(awake())
    }

    @After fun cleanup() { bridge.detach(activity) }

    private fun installFlutterSurface() {
        val surface = FlutterSurfaceView(activity)
        activity.setContentView(surface)
        activity.window.decorView.measure(
            View.MeasureSpec.makeMeasureSpec(400, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(800, View.MeasureSpec.EXACTLY))
        activity.window.decorView.layout(0, 0, 400, 800)
        surface.layout(0, 0, 400, 800)
    }

    @Test @Config(sdk = [30]) fun displayCadenceClearsOnPauseBackgroundEndAndStaleSessionsAreIgnored() {
        installFlutterSurface()
        val state = mapOf("session" to "test-player", "playing" to true, "frameRate" to 24.0)
        messenger.call("state", state)
        assertEquals(24f, frameRates.last())
        messenger.call("state", state + ("playing" to false))
        assertEquals(0f, frameRates.last())
        messenger.call("state", state)
        bridge.paused(activity)
        assertEquals(0f, frameRates.last())
        messenger.call("state", state)
        assertEquals(0f, frameRates.last())
        bridge.resumed(activity)
        assertEquals(24f, frameRates.last())
        messenger.call("begin", mapOf("session" to "new-player", "video" to true))
        assertEquals(0f, frameRates.last())
        messenger.call("state", state)
        assertEquals(0f, frameRates.last())
        messenger.call("state", state + ("session" to "new-player"))
        assertEquals(24f, frameRates.last())
        messenger.call("end", mapOf("session" to "new-player"))
        assertEquals(0f, frameRates.last())
        messenger.call("state", state + ("session" to "new-player"))
        assertEquals(0f, frameRates.last())
    }

    @Test @Config(sdk = [30]) fun visiblePipKeepsCadenceButStopAndAudioReleaseIt() {
        installFlutterSurface()
        val state = mapOf("session" to "test-player", "playing" to true, "frameRate" to 50.0)
        messenger.call("state", state)
        bridge.paused(activity)
        assertEquals(0f, frameRates.last())
        assertTrue(activity.enterPictureInPictureMode(PictureInPictureParams.Builder().build()))
        bridge.pipChanged(activity, true)
        bridge.paused(activity)
        assertEquals(50f, frameRates.last())
        bridge.stopped(activity)
        assertEquals(0f, frameRates.last())
        messenger.call("begin", mapOf("session" to "audio", "video" to false))
        messenger.call("state", state + ("session" to "audio"))
        assertEquals(0f, frameRates.last())
    }

    @Test fun leanbackDevicesReportTelevisionAndIgnorePhoneRotation() {
        val context: Context = RuntimeEnvironment.getApplication()
        shadowOf(context.packageManager).setSystemFeature(PackageManager.FEATURE_LEANBACK, true)
        activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        val values = messenger.call("begin", mapOf("session" to "tv-player", "video" to true)) as Map<*, *>
        assertEquals(true, values["television"])
        messenger.call("state", mapOf("session" to "tv-player", "playing" to true, "orientation" to "portrait"))
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED, activity.requestedOrientation)
    }

    @Test fun televisionUiModeIsDetectedWithoutLeanbackHardware() {
        RuntimeEnvironment.setQualifiers("television")
        val values = messenger.call("begin", mapOf("session" to "tv-player", "video" to true)) as Map<*, *>
        assertEquals(true, values["television"])
    }

    @Test fun activityPauseReportsHiddenBeforeActivityStop() {
        bridge.paused(activity)
        val event = messenger.sent.single()
        assertEquals("action", event.method)
        val data = event.arguments as Map<*, *>
        assertEquals("test-player", data["session"])
        assertEquals("hidden", data["action"])
    }

    @Test fun visiblePictureInPictureDoesNotPauseButHiddenPlaybackDoes() {
        assertTrue(activity.enterPictureInPictureMode(PictureInPictureParams.Builder().build()))
        bridge.paused(activity)
        assertTrue(messenger.sent.isEmpty())
        bridge.stopped(activity)
        assertEquals("hidden", (messenger.sent.single().arguments as Map<*, *>)["action"])
    }

    @Test fun endedAndReplacedActivitiesCannotPauseTheCurrentSession() {
        val previous = activity
        activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        bridge.attach(activity)
        messenger.sent.clear()
        bridge.paused(previous)
        assertTrue(messenger.sent.isEmpty())
        messenger.call("end", mapOf("session" to "test-player"))
        bridge.paused(activity)
        assertTrue(messenger.sent.isEmpty())
    }

    @Test fun videoKeepsBarsHiddenInBothOrientationsWithControlsVisibleAndRestoresOnExit() {
        // Give Robolectric an explicit pre-playback visibility snapshot.
        val bars = WindowInsetsCompat.Type.systemBars()
        windowInsets = WindowInsetsCompat.Builder()
            .setInsets(bars, CompatInsets.of(0, 24, 0, 24))
            .setInsetsIgnoringVisibility(bars, CompatInsets.of(0, 24, 0, 24))
            .setVisible(bars, true).build()
        assertTrue(windowInsets!!.isVisible(WindowInsetsCompat.Type.statusBars()))
        assertTrue(windowInsets!!.isVisible(WindowInsetsCompat.Type.navigationBars()))
        messenger.call("begin", mapOf("session" to "test-player", "video" to true))
        val state = mapOf("session" to "test-player", "playing" to true,
            "controlsVisible" to true, "orientation" to "landscape")
        fun barsHidden() = activity.window.decorView.systemUiVisibility and View.SYSTEM_UI_FLAG_FULLSCREEN != 0
        fun navigationHidden() = activity.window.decorView.systemUiVisibility and View.SYSTEM_UI_FLAG_HIDE_NAVIGATION != 0
        assertTrue(barsHidden())
        assertTrue(navigationHidden())
        messenger.call("state", state)
        assertTrue(barsHidden())
        assertTrue(navigationHidden())
        messenger.call("state", state + ("playing" to false))
        assertTrue(barsHidden())
        messenger.call("state", state + ("controlsVisible" to false))
        messenger.call("state", state)
        assertTrue(barsHidden())
        // Android can expose bars while rotating or returning from another app.
        activity.window.decorView.systemUiVisibility = 0
        bridge.configurationChanged(activity)
        assertTrue(barsHidden())
        activity.window.decorView.systemUiVisibility = 0
        bridge.resumed(activity)
        assertTrue(barsHidden())
        messenger.call("state", state + ("orientation" to "portrait"))
        assertTrue(barsHidden())
        assertTrue(navigationHidden())
        messenger.call("state", state + ("orientation" to "portrait") + ("playing" to false))
        assertTrue(barsHidden())
        activity.window.decorView.systemUiVisibility = 0
        bridge.configurationChanged(activity)
        assertTrue(barsHidden())
        assertTrue(navigationHidden())
        activity.window.decorView.systemUiVisibility = 0
        bridge.resumed(activity)
        assertTrue(barsHidden())
        assertTrue(navigationHidden())
        messenger.call("state", state)
        messenger.call("end", mapOf("session" to "test-player"))
        assertFalse(barsHidden())
        assertFalse(navigationHidden())
        bridge.configurationChanged(activity)
        assertFalse(barsHidden())
    }

    @Test fun systemRotationKeepsVideoBarsHiddenAndLeavesAudioBarsVisible() {
        val state = mapOf("session" to "test-player", "playing" to true,
            "controlsVisible" to true, "orientation" to "system")
        messenger.call("state", state)
        RuntimeEnvironment.setQualifiers("land")
        assertEquals(Configuration.ORIENTATION_LANDSCAPE, activity.resources.configuration.orientation)
        bridge.configurationChanged(activity)
        assertTrue(activity.window.decorView.systemUiVisibility and View.SYSTEM_UI_FLAG_FULLSCREEN != 0)
        RuntimeEnvironment.setQualifiers("port")
        bridge.configurationChanged(activity)
        assertTrue(activity.window.decorView.systemUiVisibility and View.SYSTEM_UI_FLAG_FULLSCREEN != 0)
        assertTrue(activity.window.decorView.systemUiVisibility and View.SYSTEM_UI_FLAG_HIDE_NAVIGATION != 0)
        RuntimeEnvironment.setQualifiers("land")
        messenger.call("begin", mapOf("session" to "audio", "video" to false))
        messenger.call("state", state + ("session" to "audio"))
        assertEquals(0, activity.window.decorView.systemUiVisibility and View.SYSTEM_UI_FLAG_FULLSCREEN)
    }

    @Test @Config(sdk = [30]) fun hiddenSystemBarsKeepTheSameSafeBounds() {
        val view = View(activity)
        activity.setContentView(view)
        val decor = activity.window.decorView
        decor.measure(
            View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(1920, View.MeasureSpec.EXACTLY))
        decor.layout(0, 0, 1080, 1920)
        val content = activity.findViewById<ViewGroup>(android.R.id.content)
        content.layout(0, 0, 1080, 1920)
        val bars = WindowInsetsCompat.Type.statusBars() or WindowInsetsCompat.Type.navigationBars()
        val system = CompatInsets.of(0, 72, 0, 60)
        val displayCutout = WindowInsetsCompat.Type.displayCutout()
        fun snapshot(visible: Boolean, cutout: CompatInsets = CompatInsets.NONE): Map<*, *> {
            val insets = WindowInsetsCompat.Builder()
                .setInsets(bars, if (visible) system else CompatInsets.NONE)
                .setInsetsIgnoringVisibility(bars, system)
                .setVisible(bars, visible)
                .setInsets(displayCutout, cutout)
                .setInsetsIgnoringVisibility(displayCutout, cutout)
                .build()
            windowInsets = insets
            val reply = messenger.call("systemInsets", mapOf("session" to "test-player")) as Map<*, *>
            return reply["systemInsets"] as Map<*, *>
        }
        val shown = snapshot(true)
        val hidden = snapshot(false)
        assertEquals(shown, hidden)
        val density = activity.resources.displayMetrics.density.toDouble()
        assertEquals(72.0 / density, hidden["top"] as Double, .01)
        assertEquals(60.0 / density, hidden["bottom"] as Double, .01)
        assertEquals(1080.0 / density, hidden["width"] as Double, .01)
        assertEquals(1920.0 / density, hidden["height"] as Double, .01)
        val screen = hidden["cutout"] as Map<*, *>
        for (edge in listOf("left", "top", "right", "bottom")) {
            assertEquals(0.0, screen[edge] as Double, .01)
        }
        val cameraLeft = snapshot(false, CompatInsets.of(90, 0, 0, 0))
        assertEquals(90.0 / density, (cameraLeft["cutout"] as Map<*, *>)["left"] as Double, .01)
        assertEquals(0.0, (cameraLeft["cutout"] as Map<*, *>)["top"] as Double, .01)
        assertEquals(0.0, (cameraLeft["cutout"] as Map<*, *>)["bottom"] as Double, .01)
        val cameraRight = snapshot(false, CompatInsets.of(0, 0, 90, 0))
        assertEquals(0.0, (cameraRight["cutout"] as Map<*, *>)["left"] as Double, .01)
        assertEquals(90.0 / density, (cameraRight["cutout"] as Map<*, *>)["right"] as Double, .01)
        // Some windows already exclude the cutout; do not count it twice.
        content.layout(90, 0, 1080, 1920)
        val consumed = snapshot(false, CompatInsets.of(90, 0, 0, 0))
        assertEquals(0.0, (consumed["cutout"] as Map<*, *>)["left"] as Double, .01)
    }

    @Test @Config(sdk = [30]) fun cutoutBoundsUseContentCoordinatesAndPreserveWaterfallEdges() {
        activity.setContentView(View(activity))
        val decor = activity.window.decorView
        decor.measure(
            View.MeasureSpec.makeMeasureSpec(2712, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(1220, View.MeasureSpec.EXACTLY))
        decor.layout(0, 0, 2712, 1220)
        val content = activity.findViewById<ViewGroup>(android.R.id.content)
        content.layout(0, 0, 2712, 1220)
        val safeInsets = CompatInsets.of(132, 6, 0, 6)
        val camera = Rect(0, 549, 132, 671)
        val cutout = DisplayCutoutCompat(safeInsets, camera, null, null, null, CompatInsets.of(0, 6, 0, 6))
        val displayCutout = WindowInsetsCompat.Type.displayCutout()
        windowInsets = WindowInsetsCompat.Builder()
            .setDisplayCutout(cutout)
            .setInsets(displayCutout, safeInsets)
            .setInsetsIgnoringVisibility(displayCutout, safeInsets)
            .build()
        fun screenBounds(): Map<*, *> {
            val reply = messenger.call("systemInsets", mapOf("session" to "test-player")) as Map<*, *>
            return (reply["systemInsets"] as Map<*, *>)["cutout"] as Map<*, *>
        }
        val density = activity.resources.displayMetrics.density.toDouble()
        val full = screenBounds()
        val rect = (full["bounds"] as List<*>).single() as Map<*, *>
        assertEquals(0.0, rect["left"] as Double, .01)
        assertEquals(549.0 / density, rect["top"] as Double, .01)
        assertEquals(132.0 / density, rect["right"] as Double, .01)
        assertEquals(671.0 / density, rect["bottom"] as Double, .01)
        val waterfall = full["waterfall"] as Map<*, *>
        assertEquals(6.0 / density, waterfall["top"] as Double, .01)
        assertEquals(6.0 / density, waterfall["bottom"] as Double, .01)

        // Content may already exclude some or all of the physical cutout.
        content.layout(60, 0, 2712, 1220)
        val partial = (screenBounds()["bounds"] as List<*>).single() as Map<*, *>
        assertEquals(0.0, partial["left"] as Double, .01)
        assertEquals(72.0 / density, partial["right"] as Double, .01)
        content.layout(132, 0, 2712, 1220)
        assertTrue((screenBounds()["bounds"] as List<*>).isEmpty())
    }
}
