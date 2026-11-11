package com.asterlink.app

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.SurfaceView
import android.view.WindowManager
import android.widget.FrameLayout
import io.flutter.embedding.android.FlutterSurfaceView
import org.junit.After
import org.junit.Before
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.annotation.Resetter
import java.time.Duration
import java.util.concurrent.Executor

@Implements(PixelCopy::class)
class ThemePixelCopy {
    companion object {
        var calls = 0
        var source: SurfaceView? = null
        var crop: Rect? = null
        var held: Runnable? = null
        var delayed = false
        var failed = false
        @JvmStatic @Resetter fun reset() {
            calls = 0; source = null; crop = null; held = null; delayed = false; failed = false
        }
        @JvmStatic @Implementation fun request(view: SurfaceView, area: Rect, bitmap: Bitmap,
            listener: PixelCopy.OnPixelCopyFinishedListener, handler: Handler) {
            calls++; source = view; crop = Rect(area)
            bitmap.eraseColor(Color.MAGENTA)
            val finish = Runnable { listener.onPixelCopyFinished(if (failed) PixelCopy.ERROR_SOURCE_NO_DATA else PixelCopy.SUCCESS) }
            if (delayed) held = finish else handler.post(finish)
        }
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], manifest = Config.NONE, shadows = [ThemePixelCopy::class])
class ThemeFrameCaptureTest {
    private val controllers = mutableListOf<org.robolectric.android.controller.ActivityController<Activity>>()
    private fun screen(): Pair<Activity, FlutterSurfaceView> {
        val controller = Robolectric.buildActivity(Activity::class.java).setup().visible()
        controllers.add(controller)
        val activity = controller.get()
        val root = FrameLayout(activity)
        val flutter = FlutterSurfaceView(activity)
        root.addView(flutter, FrameLayout.LayoutParams(400, 800))
        activity.setContentView(root)
        activity.window.decorView.measure(android.view.View.MeasureSpec.makeMeasureSpec(400, android.view.View.MeasureSpec.EXACTLY),
            android.view.View.MeasureSpec.makeMeasureSpec(800, android.view.View.MeasureSpec.EXACTLY))
        activity.window.decorView.layout(0, 0, 400, 800)
        flutter.layout(0, 0, 400, 800)
        return activity to flutter
    }
    private fun args() = mapOf("left" to 0, "top" to 24, "right" to 400,
        "bottom" to 800, "width" to 200, "height" to 388)
    private fun idle() = shadowOf(Looper.getMainLooper()).idle()
    @Before fun setup() { ThemePixelCopy.reset() }
    @After fun cleanup() { controllers.forEach { it.pause().stop().destroy() } }

    @Test fun copiesOnlyFlutterSurfaceWithCorrectCropAndBoundedImage() {
        val (activity, flutter) = screen()
        var result: Map<String, Any>? = null
        ThemeFrameCapture(Executor { it.run() }).capture(activity, args()) { result = it }
        idle()
        assertSame(flutter, ThemePixelCopy.source)
        assertEquals(Rect(0, 24, 400, 800), ThemePixelCopy.crop)
        assertEquals(200, result!!["width"])
        assertEquals(388, result!!["height"])
        val bytes = result!!["bytes"] as ByteArray
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        assertEquals(Color.MAGENTA, bitmap.getPixel(0, 0))
        bitmap.recycle()
    }

    @Test fun failedSurfaceCompletesOnceWithoutAnOffscreenFallback() {
        val (activity, _) = screen()
        ThemePixelCopy.failed = true
        var replies = 0
        ThemeFrameCapture(Executor { it.run() }).capture(activity, args()) {
            replies++; assertNull(it)
        }
        idle()
        assertEquals(1, replies)
        assertEquals(1, ThemePixelCopy.calls)
    }

    @Test fun timeoutReturnsWithoutRecyclingInFlightOrAccumulatingFrames() {
        val (activity, _) = screen()
        ThemePixelCopy.delayed = true
        val capture = ThemeFrameCapture(Executor { it.run() })
        var replies = 0
        capture.capture(activity, args()) { replies++; assertNull(it) }
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(351))
        assertEquals(1, replies)
        capture.capture(activity, args()) { replies++; assertNull(it) }
        assertEquals(1, ThemePixelCopy.calls)
        ThemePixelCopy.held!!.run()
        idle()
        assertEquals(2, replies)
        ThemePixelCopy.delayed = false
        capture.capture(activity, args()) { assertNotNull(it) }
        idle()
        assertEquals(2, ThemePixelCopy.calls)
    }

    @Test fun missingActivityAndSecureWindowCannotCapture() {
        val capture = ThemeFrameCapture(Executor { it.run() })
        capture.capture(null, args()) { assertNull(it) }
        val (activity, _) = screen()
        activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        capture.capture(activity, args()) { assertNull(it) }
        assertEquals(0, ThemePixelCopy.calls)
    }

    @Test fun invalidCropAndLargeDimensionsCannotAllocateAnUnboundedImage() {
        assertNull(ThemeFrameCapture.CaptureRequest.parse(args() + ("right" to 401), 400, 800))
        assertNull(ThemeFrameCapture.CaptureRequest.parse(args() + ("top" to -1), 400, 800))
        assertNull(ThemeFrameCapture.CaptureRequest.parse(args() + ("width" to Double.NaN), 400, 800))
        val large = ThemeFrameCapture.CaptureRequest.parse(mapOf("left" to 0, "top" to 0,
            "right" to 4000, "bottom" to 8000, "width" to 4000, "height" to 8000), 4000, 8000)!!
        assertTrue(large.width.toLong() * large.height <= 3000000)
        assertEquals(.5, large.width.toDouble() / large.height, .001)
    }
}
