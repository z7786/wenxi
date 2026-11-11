package com.asterlink.app

import android.app.Activity
import android.graphics.SurfaceTexture
import android.os.Build
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.widget.FrameLayout
import io.flutter.embedding.android.FlutterSurfaceView
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadows.ShadowSurfaceView

// Robolectric's default SurfaceView holder returns null; supply a surface so
// these tests exercise the same validity guard as a device's display surface.
@Implements(SurfaceView::class)
class PlaybackTestSurfaceView : ShadowSurfaceView() {
    private val testHolder = object : FakeSurfaceHolder() {
        val output = Surface(SurfaceTexture(0))
        override fun getSurface(): Surface = output
    }
    @Implementation override fun getHolder(): SurfaceHolder = testHolder
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 30, 33], manifest = Config.NONE, shadows = [PlaybackTestSurfaceView::class])
class PlaybackFrameRateTest {
    private val screen = Robolectric.buildActivity(Activity::class.java).setup().visible()
    private val activity = screen.get()
    private val root = FrameLayout(activity)
    private val flutter = FlutterSurfaceView(activity)
    private val calls = mutableListOf<Pair<Surface, Float>>()
    private val cadence = PlaybackFrameRate { surface, rate -> calls.add(surface to rate) }

    init {
        root.addView(flutter, FrameLayout.LayoutParams(400, 800))
        activity.setContentView(root)
        activity.window.decorView.measure(
            View.MeasureSpec.makeMeasureSpec(400, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(800, View.MeasureSpec.EXACTLY))
        activity.window.decorView.layout(0, 0, 400, 800)
        flutter.layout(0, 0, 400, 800)
    }

    @After fun cleanup() {
        cadence.clear()
        screen.pause().stop().destroy()
    }

    @Test fun contentCadenceIsDeduplicatedAndReleased() {
        cadence.update(root, 23.976f)
        cadence.update(root, 23.976f)
        if (Build.VERSION.SDK_INT < 30) {
            assertTrue(calls.isEmpty())
            return
        }
        assertEquals(listOf(23.976f), calls.map { it.second })
        assertSame(flutter.holder.surface, calls.single().first)
        cadence.update(root, 47.952f)
        cadence.update(root, 0f)
        assertEquals(listOf(23.976f, 47.952f, 0f), calls.map { it.second })
        cadence.update(root, 60f)
        cadence.clear()
        cadence.clear()
        assertEquals(listOf(23.976f, 47.952f, 0f, 60f, 0f), calls.map { it.second })
    }

    @Test fun surfaceRecreationAndReplacementRestoreTheHint() {
        if (Build.VERSION.SDK_INT < 30) return
        cadence.update(root, 25f)
        cadence.surfaceDestroyed(flutter.holder)
        cadence.surfaceCreated(flutter.holder)
        assertEquals(listOf(25f, 25f), calls.map { it.second })
        // Moving out of the Flutter surface must release the old display vote.
        cadence.update(FrameLayout(activity), 25f)
        assertEquals(0f, calls.last().second)
        cadence.update(root, 25f)
        assertEquals(25f, calls.last().second)
    }

    @Test fun invalidRatesClearTheHintAndVendorFailureIsRetryable() {
        if (Build.VERSION.SDK_INT < 30) return
        for (rate in listOf(Float.NaN, Float.POSITIVE_INFINITY, -1f, 241f)) {
            cadence.update(root, 30f)
            cadence.update(root, rate)
            assertEquals(0f, calls.last().second)
        }
        var attempts = 0
        val failing = PlaybackFrameRate { _, _ ->
            attempts++
            if (attempts == 1) throw IllegalStateException("driver rejected hint")
        }
        failing.update(root, 24f)
        failing.update(root, 24f)
        assertEquals(2, attempts)
        failing.clear()
    }

    @Test fun unavailableSurfaceNeverReceivesAHint() {
        flutter.holder.surface.release()
        cadence.update(root, 24f)
        assertTrue(calls.isEmpty())
        cadence.clear()
    }
}
