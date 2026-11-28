package com.asterlink.app

import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.annotation.RequiresApi
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.net.URI
import java.util.Locale

/** Private service in :search; its WebView has a separate data directory. */
class SearchBrowserService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val sessions = mutableMapOf<String, WebView>()
    private val pendingOpen = mutableMapOf<String, (Boolean) -> Unit>()
    private val callbacks = mutableMapOf<String, Message>()
    private val messenger = Messenger(Handler(Looper.getMainLooper()) { message ->
        val retained = Message.obtain(message)
        try { handle(retained) } catch (_: Exception) { reply(retained, false) }
        true
    })
    override fun onBind(intent: Intent?): IBinder = messenger.binder
    private fun reply(message: Message, ok: Boolean, json: String = "{}") {
        try { message.replyTo.send(Message.obtain(null, 1).apply { arg1 = message.arg1; data = Bundle().apply { putBoolean("ok", ok); putString("json", json) } }) } catch (_: Exception) {}
    }
    private fun destroySession(session: String, expected: WebView? = null) {
        val current = sessions[session]
        if (current != null && (expected == null || current === expected)) {
            sessions.remove(session)
            pendingOpen.remove(session)?.invoke(false)
            current.stopLoading()
            current.removeJavascriptInterface("AsterSearch")
            current.destroy()
            callbacks.keys.filter { it.startsWith("$session:") }.forEach {
                callbacks.remove(it)?.let { pending -> reply(pending, false) }
            }
        } else if (expected == null) {
            pendingOpen.remove(session)?.invoke(false)
        }
    }
    private fun allowed(raw: String, hosts: Set<String>): Boolean {
        return try {
            val url = URI(raw)
            val scheme = url.scheme?.lowercase(Locale.ROOT) ?: return false
            val host = url.host?.lowercase(Locale.ROOT) ?: return false
            scheme in setOf("http", "https") &&
                url.userInfo == null &&
                (url.port == -1 || url.port in setOf(80, 443)) &&
                host.isNotEmpty() &&
                host in hosts &&
                !host.contains(':') &&
                !host.startsWith('[') &&
                !host.endsWith(']') &&
                !host.matches(Regex("[0-9.]+")) &&
                host !in setOf("localhost", "127.0.0.1")
        } catch (_: Exception) { false }
    }
    @RequiresApi(Build.VERSION_CODES.P)
    @Suppress("SetJavaScriptEnabled")
    private fun openSession(
        session: String,
        url: String,
        hosts: Set<String>,
        args: JSONObject,
        message: Message,
    ) {
        destroySession(session)
        val web = WebView(this)
        sessions[session] = web
        var loaded = false
        var settled = false
        lateinit var cancelOpen: (Boolean) -> Unit
        fun finishOpen(ok: Boolean) {
            if (settled) return
            settled = true
            if (pendingOpen[session] === cancelOpen) pendingOpen.remove(session)
            if (!ok) destroySession(session, web)
            reply(message, ok)
        }
        cancelOpen = { ok -> finishOpen(ok) }
        pendingOpen[session] = cancelOpen
        try {
            web.settings.javaScriptEnabled = true
            web.settings.allowFileAccess = false
            web.settings.allowContentAccess = false
            web.addJavascriptInterface(object {
                @JavascriptInterface fun result(id: String, json: String) {
                    if (json.length > 1048576) return
                    handler.post {
                        if (sessions[session] === web) {
                            callbacks.remove("$session:$id")?.let { reply(it, true, json) }
                        }
                    }
                }
            }, "AsterSearch")
            web.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean = !allowed(request?.url.toString(), hosts)
                override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? {
                    if (!allowed(request?.url.toString(), hosts)) return WebResourceResponse("text/plain", "utf-8", ByteArrayInputStream(byteArrayOf()))
                    return null
                }
                override fun onReceivedError(view: WebView?, request: WebResourceRequest?, error: WebResourceError?) {
                    if (request?.isForMainFrame == true) {
                        finishOpen(false)
                    }
                }
                override fun onRenderProcessGone(view: WebView?, detail: RenderProcessGoneDetail?): Boolean {
                    finishOpen(false)
                    destroySession(session, web)
                    return true
                }
                override fun onPageFinished(view: WebView?, current: String?) {
                    if (sessions[session] !== web || settled) return
                    if (!loaded) {
                        loaded = true
                        val selector = args.optString("wait_selector")
                        val waitMs = args.optLong("wait_ms", 1500).coerceIn(0, 5000)
                        fun ready(remaining: Int) {
                            if (sessions[session] !== web || settled) return
                            if (selector.isEmpty()) {
                                handler.postDelayed({
                                    if (sessions[session] === web) finishOpen(true)
                                }, waitMs)
                            } else web.evaluateJavascript("Boolean(document.querySelector(${JSONObject.quote(selector)}))") { result ->
                                if (sessions[session] !== web || settled) return@evaluateJavascript
                                if (result == "true") {
                                    handler.postDelayed({
                                        if (sessions[session] === web) finishOpen(true)
                                    }, waitMs)
                                } else if (remaining > 0) {
                                    handler.postDelayed({ ready(remaining - 1) }, 200)
                                } else {
                                    finishOpen(false)
                                }
                            }
                        }
                        ready(20)
                    }
                }
            }
            web.loadUrl(url)
        } catch (_: Exception) {
            finishOpen(false)
        }
    }
    private fun handle(message: Message) {
        val args = JSONObject(message.data.getString("json") ?: "{}")
        val session = args.optString("session")
        require(session.matches(Regex("[a-f0-9]{32}")))
        when (message.data.getString("method")) {
            "open" -> {
                if ((sessions.size >= 6 && session !in sessions) || Build.VERSION.SDK_INT < Build.VERSION_CODES.P) { reply(message, false); return }
                val url = args.getString("url")
                val declared = args.getJSONArray("hosts")
                require(declared.length() <= 32)
                val hosts = (0 until declared.length()).map { declared.getString(it).lowercase(Locale.ROOT) }.toSet()
                require(allowed(url, hosts))
                openSession(session, url, hosts, args, message)
            }
            "request" -> {
                val web = sessions[session] ?: throw IllegalStateException()
                val options = args.getJSONObject("options")
                val id = message.arg1.toString()
                callbacks["$session:$id"] = message
                val script = """(async()=>{
                  const o=${options}, id=${JSONObject.quote(id)};
                  const controller=new AbortController(), timer=setTimeout(()=>controller.abort(),Math.min(15000,(o.timeout||8)*1000));
                  try {
                    if(new URL(o.url).origin!==location.origin)throw Error('origin');
                    const headers={...o.headers};for(const h of Object.keys(headers))if(['cookie','user-agent','referer','origin','accept-language'].includes(h.toLowerCase()))delete headers[h];
                    let body; if(o.body!==undefined){body=o.encoding==='form'?new URLSearchParams(o.body).toString():o.encoding==='text'?String(o.body):JSON.stringify(o.body);if(!Object.keys(headers).some(h=>h.toLowerCase()==='content-type'))headers['Content-Type']=o.encoding==='form'?'application/x-www-form-urlencoded':'application/json';}
                    const r=await fetch(o.url,{method:o.method||'GET',headers,body,credentials:'include',redirect:'error',signal:controller.signal});
                    const reader=r.body.getReader(), decoder=new TextDecoder();let size=0,text='';
                    while(true){const chunk=await reader.read();if(chunk.done)break;size+=chunk.value.length;if(size>524288){reader.cancel();throw Error('size');}text+=decoder.decode(chunk.value,{stream:true});}
                    text+=decoder.decode();const resultHeaders={};r.headers.forEach((v,k)=>resultHeaders[k]=[v]);
                    AsterSearch.result(id,JSON.stringify({status:r.status,url:r.url,headers:resultHeaders,text}));
                  }catch(e){AsterSearch.result(id,JSON.stringify({error:true}));}finally{clearTimeout(timer);}
                })()""".trimIndent()
                web.evaluateJavascript(script, null)
                handler.postDelayed({
                    if (sessions[session] === web) {
                        callbacks.remove("$session:$id")?.let { reply(it, false) }
                    }
                }, 17000)
            }
            "close" -> {
                destroySession(session)
                reply(message, true)
            }
            else -> reply(message, false)
        }
    }
    override fun onDestroy() {
        sessions.keys.toList().forEach { destroySession(it) }
        pendingOpen.keys.toList().forEach { pendingOpen.remove(it)?.invoke(false) }
        super.onDestroy()
    }
}
