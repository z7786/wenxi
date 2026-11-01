package com.asterlink.app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicInteger

/** Uses the search process's private WebView profile, never the login profile. */
class SearchBrowserBridge(private val context: Context, engine: FlutterEngine) {
    private val handler = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "com.asterlink.app/search_browser")
    private val pending = mutableMapOf<Int, MethodChannel.Result>()
    private val queued = mutableListOf<Message>()
    private val ids = AtomicInteger()
    private var remote: Messenger? = null
    private var binding = false
    private val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
        val result = pending.remove(message.arg1)
        if (message.data.getBoolean("ok")) result?.success(message.data.getString("json"))
        else result?.error("SEARCH_BROWSER", "网页搜索请求失败", null)
        true
    })
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            remote = Messenger(service)
            queued.toList().forEach { dispatch(it) }
            queued.clear()
        }
        override fun onServiceDisconnected(name: ComponentName?) { failAll(); remote = null; binding = false }
    }
    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method !in setOf("open", "request", "close")) { result.notImplemented(); return@setMethodCallHandler }
            val id = ids.incrementAndGet()
            val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
            val payload = JSONObject(args).toString()
            if (payload.length > 1048576) { result.error("SEARCH_BROWSER", "搜索请求过大", null); return@setMethodCallHandler }
            pending[id] = result
            val message = Message.obtain(null, 1).apply {
                arg1 = id; replyTo = replies
                data = Bundle().apply { putString("method", call.method); putString("json", payload) }
            }
            handler.postDelayed({ pending.remove(id)?.error("SEARCH_BROWSER", "网页搜索超时", null) }, 20000)
            if (remote != null) dispatch(message) else {
                queued.add(message)
                if (!binding) {
                    binding = context.bindService(Intent(context, SearchBrowserService::class.java), connection, Context.BIND_AUTO_CREATE)
                    if (!binding) failAll()
                }
            }
        }
    }
    private fun dispatch(message: Message) { try { remote?.send(message) } catch (_: Exception) { failAll() } }
    private fun failAll() { pending.values.toList().forEach { it.error("SEARCH_BROWSER", "网页搜索环境不可用", null) }; pending.clear(); queued.clear() }
}
