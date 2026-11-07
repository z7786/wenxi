package com.asterlink.app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Bundle
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.w3c.dom.Element

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class ExternalOpenRequestTest {
    private lateinit var context: Context
    private lateinit var parser: ExternalOpenRequest

    @Before fun setup() {
        context = RuntimeEnvironment.getApplication()
        parser = ExternalOpenRequest(context)
    }

    private fun view(uri: String, player: Boolean, mime: String? = null) =
        Intent(Intent.ACTION_VIEW).setDataAndType(Uri.parse(uri), mime).setComponent(
            ComponentName(context, "${context.packageName}.${if (player) "PlayerEntry" else "DownloadEntry"}"))

    @Test fun playerPreservesSignedUrlNameAndHttpHeaders() {
        val url = "https://cdn.example.test/film%2F01?token=opaque%2Bvalue&part=2"
        val intent = view(url, true, "video/mp4")
            .putExtra(Intent.EXTRA_TITLE, "电影.mp4")
            .putExtra("headers", arrayOf("Referer", "https://example.test/", "Cookie", "sid=from-caller"))
            .putExtra("android.media.intent.extra.HTTP_HEADERS", Bundle().apply { putString("User-Agent", "OtherPlayer/1") })
        val result = parser.parse(intent)!!
        assertEquals("play", result["kind"])
        assertEquals(url, result["uri"])
        assertEquals("电影.mp4", result["name"])
        assertEquals(mapOf("Referer" to "https://example.test/", "Cookie" to "sid=from-caller", "User-Agent" to "OtherPlayer/1"), result["headers"])
    }

    @Test fun downloadEntryKeepsVideoDownloadsSeparateFromPlayback() {
        val result = parser.parse(view("https://example.test/film.mp4", false, "video/mp4"))!!
        assertEquals("download", result["kind"])
        assertEquals("film.mp4", result["name"])
    }

    @Test fun extensionlessVideoAndHlsCanBeOpenedWithThePlayer() {
        assertEquals("play", parser.parse(view("https://example.test/play?id=9", true))!!["kind"])
        assertEquals("play", parser.parse(view("https://example.test/hls", true, "application/vnd.apple.mpegurl"))!!["kind"])
    }

    @Test fun videoShareAcceptsStreamUriWithoutCopyingOrNetworkHeaders() {
        val intent = Intent(Intent.ACTION_SEND).setType("video/mp4")
            .setComponent(ComponentName(context, "${context.packageName}.PlayerEntry"))
            .putExtra(Intent.EXTRA_STREAM, Uri.parse("content://camera.test/videos/27"))
            .putExtra(Intent.EXTRA_TITLE, "拍摄.mp4")
            .putExtra("Cookie", "do-not-send")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val result = parser.parse(intent)!!
        assertEquals("play", result["kind"])
        assertEquals("content://camera.test/videos/27", result["uri"])
        assertEquals(emptyMap<String, String>(), result["headers"])
    }

    @Test fun textShareAndMagnetStayAvailableForExistingParser() {
        val shared = "https://pan.quark.cn/s/abc123 提取码: 1234"
        val result = parser.parse(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, shared))!!
        assertEquals("share", result["kind"])
        assertEquals(shared, result["text"])
        val magnet = "magnet:?xt=urn:btih:0123456789012345678901234567890123456789"
        assertEquals(magnet, parser.parse(view(magnet, false))!!["text"])
        assertNull(parser.parse(Intent(Intent.ACTION_MAIN)))
    }

    @Test fun textSelectionAndCloudAliasesUseTheShareParser() {
        val text = "https://pan.baidu.com/s/1example 提取码：a1B2"
        val selected = Intent(Intent.ACTION_PROCESS_TEXT).setType("text/plain")
            .putExtra(Intent.EXTRA_PROCESS_TEXT, text)
        assertEquals("share", parser.parse(selected)!!["kind"])
        assertEquals(text, parser.parse(selected)!!["text"])
        assertEquals("error", parser.parse(Intent(Intent.ACTION_PROCESS_TEXT))!!["kind"])
        assertEquals("error", parser.parse(Intent(Intent.ACTION_PROCESS_TEXT)
            .putExtra(Intent.EXTRA_PROCESS_TEXT, "x".repeat(65537)))!!["kind"])
        val cloud = view("https://pan.quark.cn/s/abc123?pwd=1234", false)
            .setComponent(ComponentName(context.packageName, "com.asterlink.app.link.QuarkEntry"))
        val result = parser.parse(cloud)!!
        assertEquals("share", result["kind"])
        assertEquals(cloud.dataString, result["text"])
    }

    @Test fun customProtocolIsPassedOnceToTheSharedDartDecoder() {
        val url = "wenxi://resolve?url=https%3A%2F%2Fpan.quark.cn%2Fs%2Fabc%3Ftoken%3Da%252Bb&pwd=1234"
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            .setComponent(ComponentName(context.packageName, "com.asterlink.app.link.ProtocolEntry"))
        assertEquals(mapOf("launchUri" to url), parser.parse(intent))
    }

    @Test fun invalidAndPrivateInputsAreRejectedWithoutOpeningAnything() {
        for (url in listOf("javascript:alert(1)", "ftp://example.test/a", "file:///data/data/com.asterlink.app/files/vault",
            "file:///storage/../data/private", "content://${context.packageName}.files/files/vault", "https://user:secret@example.test/file")) {
            assertEquals(url, "error", parser.parse(view(url, true))!!["kind"])
        }
        assertEquals("error", parser.parse(view("content://files.test/file.apk", false))!!["kind"])
        assertEquals("error", parser.parse(view("https://example.test/${"a".repeat(17000)}", true))!!["kind"])
        assertEquals("error", parser.parse(Intent(Intent.ACTION_SEND).setType("text/plain"))!!["kind"])
    }

    @Test fun unsafeHeadersAreDroppedAndCaseDuplicatesHaveOneValue() {
        val intent = view("https://example.test/a", true).putExtra("headers", arrayOf(
            "Cookie", "old", "cookie", "new", "Host", "wrong.test", "Range", "bytes=20-",
            "X-Injected", "safe\r\nAuthorization: hidden", "Bad Header", "x", "X-Allowed", "yes", "orphan"))
        assertEquals(mapOf("cookie" to "new", "X-Allowed" to "yes"), parser.parse(intent)!!["headers"])
    }

    @Test fun requestsAreDrainedOnceButASecondUserOpenOfTheSameUrlIsAccepted() {
        val queue = ExternalOpenQueue()
        val request = parser.parse(view("https://example.test/a", true))!!
        assertTrue(queue.offer("activity-instance-1", request))
        assertFalse(queue.offer("activity-instance-1", request))
        assertEquals(1, queue.take().size)
        assertTrue(queue.take().isEmpty())
        assertFalse(queue.offer("activity-instance-1", request))
        assertTrue(queue.offer("next-user-open", request))
        assertEquals("next-user-open", queue.take().single()["id"])
    }

    @Test fun intakeMemoryIsBoundedWhenTheUiHasNotStarted() {
        val queue = ExternalOpenQueue()
        repeat(1000) { queue.offer("open-$it", mapOf("kind" to "download", "uri" to "https://example.test/$it")) }
        val values = queue.take()
        assertEquals(16, values.size)
        assertEquals("open-999", values.last()["id"])
    }

    private val ns = "http://schemas.android.com/apk/res/android"
    private fun Element.attr(name: String) = getAttributeNS(ns, name)
    private fun Element.children(tag: String): List<Element> = (0 until childNodes.length)
        .mapNotNull { childNodes.item(it) as? Element }.filter { it.tagName == tag }
    private fun manifest(): Element = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        .newDocumentBuilder().parse(File("src/main/AndroidManifest.xml")).documentElement

    private fun filters(alias: Element): List<IntentFilter> = alias.children("intent-filter").map { element ->
        IntentFilter().apply {
            element.children("action").forEach { addAction(it.attr("name")) }
            element.children("category").forEach { addCategory(it.attr("name")) }
            element.children("data").forEach { data ->
                data.attr("scheme").takeIf(String::isNotEmpty)?.let(::addDataScheme)
                data.attr("mimeType").takeIf(String::isNotEmpty)?.let(::addDataType)
            }
        }
    }
    private fun matches(filters: List<IntentFilter>, uri: String, mime: String? = null, action: String = Intent.ACTION_VIEW): Boolean {
        val data = Uri.parse(uri)
        return filters.any { it.match(action, mime, data.scheme, data, setOf(Intent.CATEGORY_DEFAULT), "test") >= 0 }
    }

    @Test fun manifestExposesBothChoicesForNetworkMediaAndKeepsLocalApksOut() {
        val app = manifest().children("application").single()
        val aliases = app.children("activity-alias").associateBy { it.attr("name") }
        val downloads = filters(aliases.getValue(".DownloadEntry"))
        val player = filters(aliases.getValue(".PlayerEntry"))
        for (mime in listOf("video/mp4", "application/vnd.apple.mpegurl", "application/dash+xml", "application/mp4", "application/x-matroska")) {
            assertTrue(matches(downloads, "https://example.test/play?id=1", mime))
            assertTrue(matches(player, "https://example.test/play?id=1", mime))
        }
        for (mime in listOf(null, "text/html", "application/xhtml+xml")) {
            assertFalse(matches(downloads, "https://example.test/page", mime))
            assertFalse(matches(player, "https://example.test/page", mime))
        }
        for (mime in listOf("application/octet-stream", "application/pdf", "application/zip", "application/x-bittorrent",
            "audio/mpeg", "image/jpeg", "text/plain", "text/csv")) {
            assertTrue("File type missing: $mime", matches(downloads, "https://example.test/file", mime))
        }
        assertTrue(matches(player, "content://videos.test/12", "video/mp4"))
        assertTrue(matches(player, "file:///storage/emulated/0/video.mp4", "video/mp4"))
        assertTrue(matches(downloads, "https://example.test/app.apk", FileOpening.APK_MIME))
        for (uri in listOf("content://downloads.test/12", "file:///storage/emulated/0/app.apk")) {
            assertFalse(matches(downloads, uri, FileOpening.APK_MIME))
            assertFalse(matches(player, uri, FileOpening.APK_MIME))
        }
        assertEquals("文析助手下载器", aliases.getValue(".DownloadEntry").attr("label"))
        assertEquals("文析助手播放器", aliases.getValue(".PlayerEntry").attr("label"))
    }

    @Test fun installPermissionProviderGrantsAndManualRoutingAreDeclared() {
        val manifest = manifest()
        assertTrue(manifest.children("uses-permission").any { it.attr("name") == "android.permission.REQUEST_INSTALL_PACKAGES" })
        val app = manifest.children("application").single()
        val main = app.children("activity").single { it.attr("name") == ".MainActivity" }
        assertEquals("singleTask", main.attr("launchMode"))
        assertEquals("false", main.children("meta-data").single { it.attr("name") == "flutter_deeplinking_enabled" }.attr("value"))
        val provider = app.children("provider").single { it.attr("name") == "androidx.core.content.FileProvider" }
        assertEquals("false", provider.attr("exported"))
        assertEquals("true", provider.attr("grantUriPermissions"))
    }
}
