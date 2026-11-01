package com.asterlink.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/** The relay must remain readable by a TV while the phone screen is off. */
class CastService : Service() {
    private val keeper get() = (application as CastServiceOwner).casting
    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null
    private var foreground = false
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!keeper.started(this)) finish()
        // The Dart relay cannot be restored after process death.
        return START_NOT_STICKY
    }

    @Suppress("DEPRECATION")
    fun show() {
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel("asterlink.cast", "电视投屏", NotificationManager.IMPORTANCE_LOW).apply {
                    setShowBadge(false); setSound(null, null); enableVibration(false)
                }
            )
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(this, "asterlink.cast")
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setContentTitle("电视投屏中")
            .setContentText("正在为电视中转视频 · 点击返回播放控制")
            .setContentIntent(open).setOngoing(true).setSilent(true).setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE).build()
        ServiceCompat.startForeground(this, 409, notification,
            if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK else 0)
        foreground = true
        if (wake == null) {
            wake = (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "AsterLink:CastRelay").apply {
                    setReferenceCounted(false); acquire()
                }
            wifi = (applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager)
                ?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "AsterLink:CastRelay")?.apply {
                    setReferenceCounted(false); acquire()
                }
        }
    }

    fun finish() { release(); stopSelf() }
    private fun release() {
        wake?.let { if (it.isHeld) it.release() }; wake = null
        wifi?.let { if (it.isHeld) it.release() }; wifi = null
        if (foreground) ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        foreground = false
    }
    override fun onTimeout(startId: Int, fgsType: Int) { keeper.stop() }
    override fun onDestroy() {
        release()
        keeper.destroyed(this)
        super.onDestroy()
    }
}
