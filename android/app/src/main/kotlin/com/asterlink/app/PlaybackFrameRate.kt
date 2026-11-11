package com.asterlink.app

import android.os.Build
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import io.flutter.embedding.android.FlutterSurfaceView
import kotlin.math.abs

/** The video texture is consumed by Flutter, so only Flutter's final display
 * surface can vote for the screen cadence. Never force a display mode switch. */
internal class PlaybackFrameRate(
    private val setRate: (Surface, Float) -> Unit = { surface, rate ->
        if (Build.VERSION.SDK_INT >= 31) {
            surface.setFrameRate(rate, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE,
                Surface.CHANGE_FRAME_RATE_ONLY_IF_SEAMLESS)
        } else if (Build.VERSION.SDK_INT >= 30) {
            // The two-argument API only performs seamless switches.
            surface.setFrameRate(rate, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)
        }
    },
) : SurfaceHolder.Callback {
    private var view: SurfaceView? = null
    private var requested = 0f
    private var applied: Float? = null

    fun update(root: View, frameRate: Float) {
        if (Build.VERSION.SDK_INT < 30) return
        requested = if (frameRate.isFinite() && frameRate in 1f..240f) frameRate else 0f
        val target = findSurface(root)
        if (view !== target) {
            detach()
            view = target
            target?.holder?.addCallback(this)
        }
        apply()
    }

    fun clear() {
        requested = 0f
        detach()
    }

    private fun detach() {
        val previous = view
        if (previous != null) {
            if (applied != null && applied != 0f && previous.holder.surface.isValid) {
                runCatching { setRate(previous.holder.surface, 0f) }
            }
            previous.holder.removeCallback(this)
        }
        view = null
        applied = null
    }

    private fun apply() {
        val surface = view?.holder?.surface ?: return
        if (!surface.isValid || applied?.let { abs(it - requested) < .001f } == true) return
        // Vendor-specific failures must never interrupt playback. A later state
        // update or surface callback can retry a failed hint.
        runCatching { setRate(surface, requested) }.onSuccess { applied = requested }
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        applied = null
        apply()
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = apply()

    override fun surfaceDestroyed(holder: SurfaceHolder) { applied = null }

    private fun findSurface(root: View): SurfaceView? {
        if (root is FlutterSurfaceView) return root
        if (root is ViewGroup) for (index in 0 until root.childCount) {
            findSurface(root.getChildAt(index))?.let { return it }
        }
        return null
    }
}
