package com.asterlink.app

import android.app.Service
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.net.URI

/** Private service in :search; its WebView has a separate data directory. */
class SearchBrowserService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val sessions = mutableMapOf<String, WebView>()
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
    private fun allowed(raw: String, hosts: Set<String>): Boolean {
        return try {
            val url = URI(raw)
            url.scheme in setOf("http", "https") && url.userInfo == null && (url.port == -1 || url.port in setOf(80, 443)) &&
                url.host in hosts && !url.host.matches(Regex("[0-9.]+")) && url.host !in setOf("localhost", "127.0.0.1")
        } catch (_: Exception) { false }
    }
    @Suppress("SetJavaScriptEnabled")
    private fun handle(message: Message) {
        val args = JSONObject(message.data.getString("json") ?: "{}")
        val session = args.optString("session")
        require(session.matches(Regex("[a-f0-9]{32}")))
        when (message.data.getString("method")) {
            "open" -> {
                if (sessions.size >= 6 || android.os.Build.VERSION.SDK_INT < 28) { reply(message, false); return }
                val url = args.getString("url")
                val declared = args.getJSONArray("hosts")
                require(declared.length() <= 32)
                val hosts = (0 until declared.length()).map { declared.getString(it) }.toSet()
                require(allowed(url, hosts))
                val web = WebView(this)
                sessions[session] = web
                web.settings.javaScriptEnabled = true
                web.settings.allowFileAccess = false
                web.settings.allowContentAccess = false
                web.addJavascriptInterface(object {
                    @JavascriptInterface fun result(id: String, json: String) {
                        if (json.length > 1048576) return
                        handler.post { callbacks.remove("$session:$id")?.let { reply(it, true, json) } }
                    }
                }, "AsterSearch")
                var loaded = false
                web.webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean = !allowed(request?.url.toString(), hosts)
                    override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? {
                        if (!allowed(request?.url.toString(), hosts)) return WebResourceResponse("text/plain", "utf-8", ByteArrayInputStream(byteArrayOf()))
                        return null
                    }
                    override fun onPageFinished(view: WebView?, current: String?) {
                        if (!loaded) {
                            loaded = true
                            val selector = args.optString("wait_selector")
                            fun ready(remaining: Int) {
                                if (selector.isEmpty()) {
                                    handler.postDelayed({ reply(message, true) }, args.optLong("wait_ms", 1500).coerceIn(0, 5000))
                                } else web.evaluateJavascript("Boolean(document.querySelector(${JSONObject.quote(selector)}))") { result ->
                                    if (result == "true") handler.postDelayed({ reply(message, true) }, args.optLong("wait_ms", 1500).coerceIn(0, 5000))
                                    else if (remaining > 0) handler.postDelayed({ ready(remaining - 1) }, 200)
                                    else reply(message, false)
                                }
                            }
                            ready(20)
                        }
                    }
                }
                web.loadUrl(url)
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
                handler.postDelayed({ callbacks.remove("$session:$id")?.let { reply(it, false) } }, 17000)
            }
            "close" -> {
                sessions.remove(session)?.apply { stopLoading(); removeJavascriptInterface("AsterSearch"); destroy() }
                callbacks.keys.filter { it.startsWith("$session:") }.forEach { callbacks.remove(it)?.let { pending -> reply(pending, false) } }
                reply(message, true)
            }
            else -> reply(message, false)
        }
    }
    override fun onDestroy() { sessions.values.forEach { it.destroy() }; sessions.clear(); super.onDestroy() }
}
