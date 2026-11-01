package com.asterlink.app

import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

interface CastServiceOwner { val casting: CastBridge }

/** Casting owns its locks independently of LAN file sharing and downloads. */
class CastBridge(private val context: Context, engine: FlutterEngine? = null,
    private val report: (String, Throwable) -> Unit = { _, _ -> }) {
    private val main = Handler(Looper.getMainLooper())
    private val multicast = mutableMapOf<String, WifiManager.MulticastLock>()
    private var token: String? = null
    private var pending: MethodChannel.Result? = null
    private var service: CastService? = null
    private val timeout = Runnable { failed(IllegalStateException("投屏后台服务启动超时")) }
    internal val running get() = service != null
    internal val heldDiscoveryLocks get() = multicast.values.count { it.isHeld }

    init {
        engine?.let {
            MethodChannel(it.dartExecutor.binaryMessenger, "com.asterlink.app/cast").setMethodCallHandler(::handle)
        }
    }
    internal fun handle(call: MethodCall, result: MethodChannel.Result) {
            val owner = call.argument<String>("token").orEmpty()
            if (owner.isBlank() || owner.length > 128) {
                result.error("cast", "投屏会话无效", null)
                return
            }
            val enabled = call.argument<Boolean>("enabled") == true
            try {
                when (call.method) {
                    "network" -> {
                        if (enabled && !multicast.containsKey(owner)) {
                            check(multicast.size < 8)
                            val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                            val lock = checkNotNull(wifi).createMulticastLock("AsterLink:CastDiscovery")
                            lock.setReferenceCounted(false)
                            lock.acquire()
                            multicast[owner] = lock
                        } else if (!enabled) {
                            multicast.remove(owner)?.let { if (it.isHeld) it.release() }
                        }
                        result.success(null)
                    }
                    "active" -> {
                        if (!enabled) {
                            if (token == owner) stop()
                            result.success(null)
                        } else if (token == owner && service != null) {
                            result.success(null)
                        } else {
                            stop()
                            token = owner
                            pending = result
                            main.postDelayed(timeout, 8000)
                            ContextCompat.startForegroundService(context, Intent(context, CastService::class.java))
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                if (pending === result) failed(error)
                else result.error("cast", "无法启用投屏网络，请检查系统权限", null)
            }
    }

    fun started(current: CastService): Boolean {
        if (token == null) return false
        return try {
            current.show()
            service = current
            main.removeCallbacks(timeout)
            pending?.success(null)
            pending = null
            true
        } catch (error: Exception) {
            failed(error)
            false
        }
    }

    fun destroyed(current: CastService) {
        if (service === current) { service = null; token = null }
    }

    fun stop() {
        token = null
        main.removeCallbacks(timeout)
        pending?.error("cast", "投屏已取消", null)
        pending = null
        service?.finish()
        service = null
        context.stopService(Intent(context, CastService::class.java))
    }

    private fun failed(error: Exception) {
        pending?.error("cast", "无法保持投屏后台运行，请返回应用后重试", null)
        pending = null
        stop()
        report("player.cast_service_failed", error)
    }
}
