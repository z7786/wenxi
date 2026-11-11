package com.alexmercerind.media_kit_video

import android.graphics.SurfaceTexture
import android.os.Looper
import android.view.Surface
import com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper
import io.flutter.view.TextureRegistry
import java.lang.reflect.Proxy
import java.time.Duration
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements

@Implements(MediaKitAndroidHelper::class)
class TextureTestJni {
    companion object {
        var serial = 1000L
        val released = mutableListOf<Long>()
        @JvmStatic @Implementation fun __staticInitializer__() {}
        @JvmStatic @Implementation fun newGlobalObjectRef(value: Any): Long = ++serial
        @JvmStatic @Implementation fun deleteGlobalObjectRef(value: Long) { released.add(value) }
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE, shadows = [TextureTestJni::class])
class PlaybackTextureTest {
    @Test fun resizeReusesSurfaceAndCleanupReleasesEveryReferenceOnce() {
        TextureTestJni.released.clear()
        var surface = Surface(SurfaceTexture(0))
        var width = 1
        var height = 1
        var callback: TextureRegistry.SurfaceProducer.Callback? = null
        var producerReleases = 0
        val producer = Proxy.newProxyInstance(javaClass.classLoader,
            arrayOf(TextureRegistry.SurfaceProducer::class.java)) { _, method, args ->
            when (method.name) {
                "id" -> 7L
                "getSurface" -> surface
                "getWidth" -> width
                "getHeight" -> height
                "setSize" -> { width = args!![0] as Int; height = args[1] as Int; null }
                "setCallback" -> { callback = args?.get(0) as? TextureRegistry.SurfaceProducer.Callback; null }
                "release" -> { producerReleases++; null }
                else -> null
            }
        } as TextureRegistry.SurfaceProducer
        val registry = Proxy.newProxyInstance(javaClass.classLoader,
            arrayOf(TextureRegistry::class.java)) { _, method, _ ->
            if (method.name == "createSurfaceProducer") producer else null
        } as TextureRegistry
        val updates = mutableListOf<Long>()
        val output = VideoOutput(registry) { _, wid, _, _ -> updates.add(wid) }
        output.setSurfaceSize(1920, 1080)
        val first = updates.last()
        output.setSurfaceSize(960, 540)
        assertEquals(first, updates.last())
        val count = updates.size
        output.setSurfaceSize(960, 540)
        assertEquals(count, updates.size)
        callback!!.onSurfaceCleanup()
        callback!!.onSurfaceCleanup()
        surface = Surface(SurfaceTexture(0))
        callback!!.onSurfaceAvailable()
        val second = updates.last()
        assertNotEquals(first, second)
        // Replacement without a cleanup callback also releases the previous JNI ref.
        surface = Surface(SurfaceTexture(0))
        callback!!.onSurfaceAvailable()
        val third = updates.last()
        output.dispose()
        output.dispose()
        output.setSurfaceSize(1, 1)
        assertEquals(1, producerReleases)
        assertNull(callback)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(6))
        assertEquals(listOf(first, second, third), TextureTestJni.released)
        assertEquals(0L, updates.last())
    }
}
