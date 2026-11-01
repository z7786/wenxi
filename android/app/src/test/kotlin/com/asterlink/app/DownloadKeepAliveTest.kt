package com.asterlink.app

import android.Manifest
import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Looper
import android.provider.Settings
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
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.annotation.Resetter
import org.robolectric.shadows.ShadowNotificationManager
import java.time.Duration

class DownloadTestApplication : Application(), DownloadServiceOwner {
    override lateinit var downloadKeepAlive: DownloadKeepAlive
}

@Implements(NotificationManager::class)
class FailingDownloadNotifications : ShadowNotificationManager() {
    companion object {
        var rejectUpdates = false
        @JvmStatic @Resetter fun resetFailure() { rejectUpdates = false }
    }
    @Implementation override fun notify(id: Int, notification: Notification) {
        if (rejectUpdates) throw SecurityException("notification update rejected")
        super.notify(id, notification)
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], manifest = Config.NONE, application = DownloadTestApplication::class)
class DownloadKeepAliveTest {
    private lateinit var app: DownloadTestApplication
    private val controllers = mutableListOf<ServiceController<FlutterDownloadService>>()
    private val commands = mutableListOf<Pair<String, (Boolean) -> Unit>>()
    private val errors = mutableListOf<String>()
    private val keeper get() = app.downloadKeepAlive
    private class Reply : MethodChannel.Result {
        var calls = 0
        var error: String? = null
        override fun success(result: Any?) { calls++ }
        override fun error(code: String, message: String?, details: Any?) { calls++; error = message }
        override fun notImplemented() { calls++; error = "not implemented" }
    }
    private fun newKeeper() {
        app.downloadKeepAlive = DownloadKeepAlive(app, { name, callback -> commands.add(name to callback) },
            { name, _ -> errors.add(name) })
    }
    private fun createService(): FlutterDownloadService = Robolectric.buildService(FlutterDownloadService::class.java)
        .also { controllers.add(it); it.create() }.get()
    private fun start(): FlutterDownloadService {
        keeper.update(DownloadNotice(1, "下载中", 10), Reply())
        return createService().also { assertEquals(Service.START_STICKY, it.onStartCommand(Intent(), 0, 1)) }
    }
    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @Before fun setup() {
        app = RuntimeEnvironment.getApplication() as DownloadTestApplication
        app.getSharedPreferences("download_keepalive", Context.MODE_PRIVATE).edit().clear().commit()
        newKeeper()
    }
    @After fun cleanup() {
        keeper.update(DownloadNotice.IDLE, Reply())
        controllers.forEach { it.destroy() }
    }

    @Test fun startIsAcknowledgedOnlyAfterForegroundAndWakeLockAreActive() {
        val reply = Reply()
        keeper.update(DownloadNotice(1, "2.0 MB/s", 30), reply)
        assertEquals(0, reply.calls)
        val service = createService()
        assertEquals(Service.START_STICKY, service.onStartCommand(Intent(), 0, 1))
        assertEquals(1, reply.calls)
        assertNull(reply.error)
        assertTrue(keeper.running)
        assertTrue(service.wakeLockHeld)
        val notification = shadowOf(service).lastForegroundNotification
        assertEquals(30, notification.extras.getInt(Notification.EXTRA_PROGRESS))
        assertEquals("2.0 MB/s", notification.extras.getString(Notification.EXTRA_TEXT))
        assertEquals(Notification.VISIBILITY_PRIVATE, notification.visibility)
        assertNotNull(notification.publicVersion)
        assertEquals("全部暂停", notification.actions.single().title)
        if (Build.VERSION.SDK_INT >= 29) {
            assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC, service.foregroundServiceType)
        }
    }

    @Test fun updatesReuseServiceAndIdleImmediatelyReleasesResources() {
        val service = start()
        val shadow = shadowOf(app)
        assertNotNull(shadow.nextStartedService)
        repeat(5) { keeper.update(DownloadNotice(2, "下载中", 20 + it), Reply()) }
        assertNull(shadow.nextStartedService)
        keeper.update(DownloadNotice.IDLE, Reply())
        assertFalse(keeper.running)
        assertFalse(service.wakeLockHeld)
        assertTrue(shadowOf(service).isStoppedBySelf)
    }

    @Test fun uploadNoticeShowsTransferActionAndTargetsUploadPage() {
        keeper.update(DownloadNotice.from(mapOf("active" to 1, "uploads" to 1, "text" to "上传 1 · 2 MB/s", "progress" to 40)), Reply())
        val service = createService()
        service.onStartCommand(Intent(), 0, 1)
        val notice = shadowOf(service).lastForegroundNotification
        assertEquals("文析助手 · 1 个传输任务", notice.extras.getString(Notification.EXTRA_TITLE))
        assertEquals("停止传输", notice.actions.single().title)
        val intent = shadowOf(notice.contentIntent).savedIntent
        assertEquals("com.asterlink.app.OPEN_TRANSFERS", intent.action)
        assertEquals("uploads", intent.getStringExtra("transferTab"))
        assertTrue(service.wakeLockHeld)
    }

    @Test fun lanListenerKeepsServiceAliveAndReturnsToDevicePage() {
        keeper.update(DownloadNotice.from(mapOf("active" to 1, "lan" to 1, "text" to "设备互联已开启")), Reply())
        val service = createService()
        service.onStartCommand(Intent(), 0, 1)
        val notice = shadowOf(service).lastForegroundNotification
        assertEquals("文析助手 · 设备互联", notice.extras.getString(Notification.EXTRA_TITLE))
        assertEquals("停止传输", notice.actions.single().title)
        assertEquals("lan", shadowOf(notice.contentIntent).savedIntent.getStringExtra("transferTab"))
        assertTrue(service.wakeLockHeld)
    }

    @Test fun stickyRestartWaitsForDartAndShowsRestoringNotification() {
        start()
        controllers.last().destroy()
        controllers.clear()
        newKeeper() // Process state lost; only the minimal wanted flag persists.
        val service = createService()
        assertEquals(Service.START_STICKY, service.onStartCommand(null, 0, 2))
        idle()
        assertTrue(commands.isEmpty())
        assertTrue(service.wakeLockHeld)
        assertEquals("正在恢复中断的下载…", shadowOf(service).lastForegroundNotification.extras.getString(Notification.EXTRA_TEXT))
        keeper.dartReady()
        idle()
        assertEquals("downloadServiceRestarted", commands.single().first)
        keeper.update(DownloadNotice.IDLE, Reply()) // No recoverable queue left.
        commands.single().second(true)
        assertFalse(service.wakeLockHeld)
    }

    @Test fun anIdleOrStoppedSessionDoesNotResurrectOnNullIntent() {
        val service = createService()
        assertEquals(Service.START_NOT_STICKY, service.onStartCommand(null, 0, 1))
        assertFalse(service.wakeLockHeld)
        keeper.dartReady()
        idle()
        assertTrue(commands.isEmpty())
    }

    @Test fun ordinaryColdLaunchClearsOldRecoveryBeforeAnyNewDownloadSession() {
        app.getSharedPreferences("download_keepalive", Context.MODE_PRIVATE).edit().putBoolean("wanted", true).commit()
        newKeeper()
        keeper.appVisible()
        assertFalse(keeper.recoveryExpected)
        keeper.dartReady()
        idle()
        assertEquals("downloadDiscardRecovery", commands.single().first)
        commands.single().second(true)
        val service = createService()
        assertEquals(Service.START_NOT_STICKY, service.onStartCommand(null, 0, 1))
        assertFalse(service.wakeLockHeld)
    }

    @Test fun aPendingStartRedeliveredAfterProcessDeathAlsoRecoversTheQueue() {
        app.getSharedPreferences("download_keepalive", Context.MODE_PRIVATE).edit().putBoolean("wanted", true).commit()
        newKeeper()
        val service = createService()
        assertEquals(Service.START_STICKY, service.onStartCommand(Intent(), 0, 1))
        keeper.dartReady()
        idle()
        assertEquals("downloadServiceRestarted", commands.single().first)
        commands.single().second(true)
    }

    @Test fun notificationPauseBeforeDartReadyIsDurableAndDeliveredLater() {
        val service = start()
        assertEquals(Service.START_NOT_STICKY,
            service.onStartCommand(Intent().setAction("pauseAll"), 0, 2))
        assertFalse(app.getSharedPreferences("download_keepalive", Context.MODE_PRIVATE).getBoolean("wanted", true))
        idle()
        assertTrue(commands.isEmpty())
        keeper.dartReady()
        idle()
        assertEquals("pauseAll", commands.single().first)
        commands.single().second(true)
        assertFalse(service.wakeLockHeld)
        assertFalse(keeper.running)
        val restarted = createService()
        assertEquals(Service.START_NOT_STICKY, restarted.onStartCommand(null, 0, 3))
    }

    @Test fun serviceStartTimeoutReportsFailureInsteadOfClaimingProtection() {
        val reply = Reply()
        keeper.update(DownloadNotice(1, "下载中"), reply)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(8))
        assertEquals(1, reply.calls)
        assertNotNull(reply.error)
        assertFalse(keeper.running)
        assertEquals(listOf("download.foreground_failed"), errors)
    }

    @Test fun systemTimeoutStopsSynchronouslyAndBlocksRestartUntilForeground() {
        val service = start()
        keeper.dartReady()
        service.onTimeout(1, 1)
        assertFalse(service.wakeLockHeld)
        assertFalse(keeper.running)
        idle()
        assertEquals("serviceTimeout", commands.single().first)
        commands.single().second(true)
        val blocked = Reply()
        keeper.update(DownloadNotice(1, "下载中"), blocked)
        assertNotNull(blocked.error)
        keeper.appVisible()
        val allowed = Reply()
        keeper.update(DownloadNotice(1, "下载中"), allowed)
        createService().onStartCommand(Intent(), 0, 2)
        assertEquals(1, allowed.calls)
        assertNull(allowed.error)
    }

    @Test fun heartbeatsRenewProtectionBeyondTheInitialLeaseThenStopOnSilence() {
        val service = start()
        keeper.dartReady()
        repeat(24) {
            keeper.update(DownloadNotice(1, "等待网络"), Reply())
            shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(30))
            assertTrue(service.wakeLockHeld)
        }
        assertTrue(commands.isEmpty())
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMinutes(2))
        assertFalse(service.wakeLockHeld)
        assertEquals("downloadServiceStalled", commands.single().first)
    }

    @Test fun aLateHeartbeatCannotRestartAStalledServiceUntilTheAppReturns() {
        val service = start()
        keeper.dartReady()
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMinutes(2))
        assertFalse(service.wakeLockHeld)
        assertEquals("downloadServiceStalled", commands.single().first)
        commands.single().second(true)
        val blocked = Reply()
        keeper.update(DownloadNotice(1, "迟到的进度"), blocked)
        assertNotNull(blocked.error)
        assertFalse(keeper.running)
        assertFalse(keeper.recoveryExpected)
        keeper.appVisible()
        val allowed = Reply()
        keeper.update(DownloadNotice(1, "继续下载"), allowed)
        createService().onStartCommand(Intent(), 0, 2)
        assertEquals(1, allowed.calls)
        assertNull(allowed.error)
        assertTrue(keeper.running)
    }

    @Test fun aTimedOutPauseRetriesOnReturnAndIgnoresItsLateAcknowledgement() {
        start()
        keeper.dartReady()
        keeper.pause()
        idle()
        val late = commands.single().second
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(10))
        assertFalse(keeper.running)
        keeper.appVisible()
        idle()
        assertEquals(listOf("pauseAll", "pauseAll"), commands.map { it.first })
        commands.last().second(true)
        val reply = Reply()
        keeper.update(DownloadNotice(1, "继续下载"), reply)
        createService().onStartCommand(Intent(), 0, 2)
        late(false)
        assertNull(reply.error)
        assertTrue(keeper.running)
        assertEquals(listOf("download.pause_timeout"), errors)
    }

    @Test @Config(shadows = [FailingDownloadNotifications::class])
    fun notificationFailureCannotPreventThePauseCommandOrLeaveAWakeLock() {
        val service = start()
        shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        keeper.dartReady()
        FailingDownloadNotifications.rejectUpdates = true
        try {
            keeper.pause()
            idle()
        } finally {
            FailingDownloadNotifications.rejectUpdates = false
        }
        assertEquals("pauseAll", commands.single().first)
        commands.single().second(true)
        assertFalse(service.wakeLockHeld)
        assertFalse(keeper.running)
        assertEquals(listOf("download.pause_notice_failed"), errors)
    }

    @Test @Config(sdk = [35])
    fun grantingNotificationsRefreshesAnUnchangedNoticeWithoutRestartingTheService() {
        shadowOf(app).denyPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val service = start()
        val notice = DownloadNotice(1, "等待网络恢复")
        keeper.update(notice, Reply())
        assertTrue(service.wakeLockHeld)
        val services = shadowOf(app)
        assertNotNull(services.nextStartedService)
        shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        keeper.update(notice, Reply())
        assertNull(services.nextStartedService)
        val notification = shadowOf(app.getSystemService(NotificationManager::class.java))
            .getNotification(FlutterDownloadService.NOTIFICATION_ID)
        assertEquals("等待网络恢复", notification.extras.getString(Notification.EXTRA_TEXT))
    }

    @Test fun destructionReleasesLockAndLateRecoveryCallbackCannotUndoPause() {
        start()
        controllers.last().destroy()
        controllers.clear()
        newKeeper()
        val service = createService()
        service.onStartCommand(null, 0, 2)
        keeper.dartReady()
        idle()
        val recovery = commands.single().second
        keeper.pause()
        idle()
        recovery(false)
        assertTrue(errors.isEmpty())
        assertEquals(listOf("downloadServiceRestarted", "pauseAll"), commands.map { it.first })
        commands.last().second(true)
        assertFalse(service.wakeLockHeld)
    }

    @Test fun missingPauseAcknowledgementHasABoundedResourceLifetime() {
        val service = start()
        keeper.pause()
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(10))
        assertFalse(service.wakeLockHeld)
        assertFalse(keeper.running)
        assertEquals(listOf("download.pause_timeout"), errors)
    }

    @Test fun batteryAndNotificationButtonsUseScopedSystemSettings() {
        val activity = Robolectric.buildActivity(android.app.Activity::class.java).setup().get()
        val protection = DownloadProtection(app, keeper)
        protection.open("battery", activity)
        val battery = shadowOf(activity).nextStartedActivity
        assertEquals(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, battery.action)
        assertEquals("package:${app.packageName}", battery.data.toString())
        protection.open("app", activity)
        assertEquals(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, shadowOf(activity).nextStartedActivity.action)
        assertFalse(protection.status()["serviceRunning"] as Boolean)
        activity.finish()
    }

    @Test fun disabledDownloadChannelIsReportedEvenWhenAppNotificationsAreAllowed() {
        val notifications = app.getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(NotificationChannel(FlutterDownloadService.CHANNEL, "下载", NotificationManager.IMPORTANCE_NONE))
        assertFalse(DownloadProtection(app, keeper).status()["notificationsEnabled"] as Boolean)
    }
}
