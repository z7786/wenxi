package com.asterlink.app

import android.app.Application
import android.app.Notification
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ServiceController
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowPowerManager
import java.time.Duration

class CastTestApplication : Application(), CastServiceOwner {
    override lateinit var casting: CastBridge
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], manifest = Config.NONE, application = CastTestApplication::class)
class CastServiceTest {
    private lateinit var app: CastTestApplication
    private val controllers = mutableListOf<ServiceController<CastService>>()
    private val keeper get() = app.casting
    private class Reply : MethodChannel.Result {
        var successes = 0
        val errors = mutableListOf<String>()
        override fun success(result: Any?) { successes++ }
        override fun error(code: String, message: String?, details: Any?) { errors.add(message.orEmpty()) }
        override fun notImplemented() { fail("not implemented") }
    }
    private fun call(method: String, token: String, enabled: Boolean) = Reply().also {
        keeper.handle(MethodCall(method, mapOf("token" to token, "enabled" to enabled)), it)
    }
    private fun service(): CastService = Robolectric.buildService(CastService::class.java)
        .also { controllers.add(it); it.create() }.get()

    @Before fun setup() {
        app = RuntimeEnvironment.getApplication() as CastTestApplication
        app.casting = CastBridge(app)
    }
    @After fun teardown() {
        keeper.stop()
        controllers.forEach { it.destroy() }
        shadowOf(Looper.getMainLooper()).idle()
    }

    @Test fun foregroundAcknowledgesOnlyAfterNotificationAndReleasesWakeLockOnStop() {
        val reply = call("active", "video-a", true)
        assertEquals(0, reply.successes)
        val service = service()
        assertEquals(Service.START_NOT_STICKY, service.onStartCommand(Intent(), 0, 1))
        assertEquals(1, reply.successes)
        assertTrue(reply.errors.isEmpty())
        assertTrue(keeper.running)
        val wake = ShadowPowerManager.getLatestWakeLock()
        assertTrue(wake.isHeld)
        val notification = shadowOf(service).lastForegroundNotification
        assertEquals("电视投屏中", notification.extras.getString(Notification.EXTRA_TITLE))
        assertEquals(Notification.CATEGORY_TRANSPORT, notification.category)
        if (Build.VERSION.SDK_INT >= 29) {
            assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK, service.foregroundServiceType)
        }
        call("active", "old-video", false)
        assertTrue(keeper.running)
        call("active", "video-a", false)
        assertFalse(keeper.running)
        assertFalse(wake.isHeld)
    }

    @Test fun multicastOwnershipIsIndependentAndIdempotentAcrossConcurrentScans() {
        call("network", "scan-a", true)
        call("network", "scan-a", true)
        call("network", "scan-b", true)
        assertEquals(2, keeper.heldDiscoveryLocks)
        call("network", "scan-a", false)
        call("network", "scan-a", false)
        assertEquals(1, keeper.heldDiscoveryLocks)
        call("network", "scan-b", false)
        assertEquals(0, keeper.heldDiscoveryLocks)
    }

    @Test fun cancellationBeforeServiceStartCannotCreateAnOrphanRelayService() {
        val reply = call("active", "video-a", true)
        call("active", "video-a", false)
        val service = service()
        assertEquals(Service.START_NOT_STICKY, service.onStartCommand(Intent(), 0, 1))
        assertFalse(keeper.running)
        assertEquals(0, reply.successes)
        assertEquals(1, reply.errors.size)
        assertNull(ShadowPowerManager.getLatestWakeLock())
    }

    @Test fun missingServiceStartTimesOutOnceAndDoesNotLeaveARequestPending() {
        val reply = call("active", "video-a", true)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(9))
        assertEquals(1, reply.errors.size)
        assertEquals(0, reply.successes)
        assertFalse(keeper.running)
        assertFalse(keeper.started(service()))
        assertEquals(1, reply.errors.size)
    }
}
