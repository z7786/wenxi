package com.asterlink.app

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.Surface
import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import io.flutter.embedding.android.FlutterSurfaceView
import io.flutter.embedding.android.FlutterTextureView
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executor
import kotlin.math.floor
import kotlin.math.min
import kotlin.math.sqrt

/** Captures already rendered pixels; never calls View.draw or stores a file. */
class ThemeFrameCapture(private val worker: Executor) {
    private val main = Handler(Looper.getMainLooper())
    private var busy = false

    fun capture(activity: Activity?, args: Map<*, *>, complete: (Map<String, Any>?) -> Unit) {
        if (busy || Build.VERSION.SDK_INT < 26 || activity == null ||
            activity.isFinishing || activity.isDestroyed ||
            activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0) {
            complete(null)
            return
        }
        val source = findSurface(activity.window.decorView)
        val request = source?.let { CaptureRequest.parse(args, it.width, it.height) }
        if (source == null || request == null || !source.isAttachedToWindow || !source.isShown) {
            complete(null)
            return
        }
        val bitmap = try {
            Bitmap.createBitmap(request.width, request.height, Bitmap.Config.ARGB_8888)
        } catch (_: Exception) {
            complete(null)
            return
        }
        busy = true
        var answered = false
        var textureSurface: Surface? = null
        fun reply(value: Map<String, Any>?) {
            if (!answered) {
                answered = true
                complete(value)
            }
        }
        // A late native callback still owns the bitmap until copying finishes.
        // Do not recycle it at timeout or start accumulating more captures.
        val timeout = Runnable { reply(null) }
        main.postDelayed(timeout, 350)
        fun copied(status: Int) {
            textureSurface?.release()
            textureSurface = null
            if (status != PixelCopy.SUCCESS || answered || activity.isFinishing ||
                activity.isDestroyed || !source.isAttachedToWindow) {
                main.removeCallbacks(timeout)
                bitmap.recycle()
                busy = false
                reply(null)
                return
            }
            try {
                worker.execute {
                    val frame = try {
                        val bytes = ByteArrayOutputStream()
                        if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes)) null
                        else mapOf<String, Any>("bytes" to bytes.toByteArray(),
                            "width" to bitmap.width, "height" to bitmap.height)
                    } catch (_: Exception) { null }
                    finally { bitmap.recycle() }
                    main.post {
                        main.removeCallbacks(timeout)
                        busy = false
                        reply(if (activity.isFinishing || activity.isDestroyed ||
                            !source.isAttachedToWindow) null else frame)
                    }
                }
            } catch (_: Exception) {
                main.removeCallbacks(timeout)
                bitmap.recycle()
                busy = false
                reply(null)
            }
        }
        try {
            when (source) {
                is SurfaceView -> PixelCopy.request(source, request.crop, bitmap, ::copied, main)
                is TextureView -> {
                    val texture = source.surfaceTexture
                    if (!source.isAvailable || texture == null) copied(PixelCopy.ERROR_SOURCE_NO_DATA)
                    else {
                        val surface = Surface(texture).also { textureSurface = it }
                        PixelCopy.request(surface, request.crop, bitmap, ::copied, main)
                    }
                }
                else -> copied(PixelCopy.ERROR_SOURCE_INVALID)
            }
        } catch (_: Exception) {
            copied(PixelCopy.ERROR_UNKNOWN)
        }
    }

    private fun findSurface(view: View): View? {
        if (view is FlutterSurfaceView || view is FlutterTextureView) return view
        if (view is ViewGroup) for (index in 0 until view.childCount) {
            findSurface(view.getChildAt(index))?.let { return it }
        }
        return null
    }

    internal class CaptureRequest(val crop: Rect, val width: Int, val height: Int) {
        companion object {
            fun parse(args: Map<*, *>, sourceWidth: Int, sourceHeight: Int): CaptureRequest? {
                fun number(key: String): Int? {
                    val value = (args[key] as? Number)?.toDouble() ?: return null
                    return if (value.isFinite() && value >= 0 && value <= 100000 && value == floor(value))
                        value.toInt() else null
                }
                val left = number("left") ?: return null
                val top = number("top") ?: return null
                val right = number("right") ?: return null
                val bottom = number("bottom") ?: return null
                val width = number("width") ?: return null
                val height = number("height") ?: return null
                if (sourceWidth <= 0 || sourceHeight <= 0 || width <= 0 || height <= 0 ||
                    right <= left || bottom <= top || right > sourceWidth || bottom > sourceHeight) return null
                val crop = Rect(left, top, right, bottom)
                // Keep only a bounded, downsampled copy of the Flutter viewport.
                val scale = min(1.0, min(min(crop.width().toDouble() / width,
                    crop.height().toDouble() / height), sqrt(3000000.0 / (width.toLong() * height))))
                return CaptureRequest(crop, (width * scale).toInt().coerceAtLeast(1),
                    (height * scale).toInt().coerceAtLeast(1))
            }
        }
    }
}
