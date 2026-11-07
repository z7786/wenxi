package com.asterlink.app

import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.PatternMatcher
import android.provider.Settings
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.w3c.dom.Element

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class LinkOpeningTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val ns = "http://schemas.android.com/apk/res/android"
    private fun Element.attr(name: String) = getAttributeNS(ns, name)
    private fun Element.children(tag: String): List<Element> = (0 until childNodes.length)
        .mapNotNull { childNodes.item(it) as? Element }.filter { it.tagName == tag }
    private fun entries(): Map<String, Element> {
        val root = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
            .newDocumentBuilder().parse(File("src/main/AndroidManifest.xml")).documentElement
        val app = root.children("application").single()
        return (app.children("activity") + app.children("activity-alias")).associateBy { it.attr("name") }
    }
    private fun filters(entry: Element): List<IntentFilter> = entry.children("intent-filter").map { source ->
        IntentFilter().apply {
            source.children("action").forEach { addAction(it.attr("name")) }
            source.children("category").forEach { addCategory(it.attr("name")) }
            source.children("data").forEach { data ->
                data.attr("scheme").takeIf(String::isNotEmpty)?.let(::addDataScheme)
                data.attr("mimeType").takeIf(String::isNotEmpty)?.let(::addDataType)
                data.attr("host").takeIf(String::isNotEmpty)?.let { addDataAuthority(it, null) }
                for ((key, kind) in listOf("path" to PatternMatcher.PATTERN_LITERAL,
                    "pathPrefix" to PatternMatcher.PATTERN_PREFIX, "pathPattern" to PatternMatcher.PATTERN_SIMPLE_GLOB)) {
                    data.attr(key).takeIf(String::isNotEmpty)?.let { addDataPath(it, kind) }
                }
            }
        }
    }
    private fun matches(entry: Element, url: String, action: String = Intent.ACTION_VIEW, mime: String? = null): Boolean {
        val uri = Uri.parse(url)
        val categories = if (action == Intent.ACTION_VIEW) setOf(Intent.CATEGORY_DEFAULT, Intent.CATEGORY_BROWSABLE)
            else setOf(Intent.CATEGORY_DEFAULT)
        return filters(entry).any { it.match(action, mime, uri.scheme, uri, categories, "links-test") >= 0 }
    }

    private fun enabledMatches(entries: Map<String, Element>, url: String,
        action: String = Intent.ACTION_VIEW, mime: String? = null): Set<String> = entries.filter { (name, entry) ->
        val className = if (name.startsWith(".")) context.packageName + name else name
        val state = context.packageManager.getComponentEnabledSetting(ComponentName(context.packageName, className))
        val enabled = when (state) {
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED_USER,
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED_UNTIL_USED -> false
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
            else -> entry.attr("enabled") != "false"
        }
        enabled && entry.attr("exported") == "true" && matches(entry, url, action, mime)
    }.keys

    private val shareLinks = mapOf(
        "QuarkEntry" to "https://pan.quark.cn/s/abc123?pwd=1234",
        "UcEntry" to "https://drive.uc.cn/s/abc123",
        "BaiduEntry" to "https://pan.baidu.com/share/init?surl=abc123",
        "AliyunEntry" to "https://www.alipan.com/s/abc123",
        "TianyiEntry" to "https://cloud.189.cn/web/share?code=abc123",
        "C139Entry" to "https://yun.139.com/shareweb/#/w/i/abc123",
        "WopanEntry" to "https://pan.wo.cn/s/abc123",
        "GuangyaEntry" to "https://www.guangyapan.com/s/abc123",
        "XunleiEntry" to "https://pan.xunlei.com/s/abc123",
        "Pan115Entry" to "https://115cdn.com/s/abc123",
        "Pan123Entry" to "https://www.123865.com/s/abc123",
        "LanzouEntry" to "https://wws.lanzout.com/iabc123",
        "CtfileEntry" to "https://url95.ctfile.com/f/123-456",
        "FeijipanEntry" to "https://www.feijipan.com/#/s/abc123",
        "PikpakEntry" to "https://mypikpak.com/s/abc123",
    )

    @Test fun declaredSharePathsOpenButUnrelatedWebsitesAndLoginPagesDoNot() {
        val aliases = entries()
        for ((name, url) in shareLinks) {
            val entry = aliases.getValue("com.asterlink.app.link.$name")
            assertTrue("Missing $url", matches(entry, url))
            assertTrue("Missing HTTP fallback for $name", matches(entry, url.replace("https:", "http:")))
            assertFalse("Unrelated website captured by $name", matches(entry, "https://example.test/s/abc123"))
            assertTrue(entry.children("intent-filter").all { it.attr("autoVerify") != "true" })
        }
        assertFalse(matches(aliases.getValue("com.asterlink.app.link.QuarkEntry"), "https://pan.quark.cn/login"))
        assertFalse(matches(aliases.getValue("com.asterlink.app.link.QuarkEntry"), "https://pan.quark.cn.evil.test/s/abc123"))
        assertFalse(matches(aliases.getValue("com.asterlink.app.link.Pan115Entry"), "https://115.com/login"))
    }

    @Test fun everySettingOwnsOneEnabledAliasAndOnlyExpectedActionsAreExposed() {
        val aliases = entries()
        assertEquals(LinkOpening.targets.size, LinkOpening.targets.map { it.alias }.distinct().size)
        for (target in LinkOpening.targets) {
            val entry = aliases.getValue(target.alias)
            assertEquals("true", entry.attr("enabled"))
            assertEquals("true", entry.attr("exported"))
            assertEquals(".MainActivity", entry.attr("targetActivity"))
        }
        assertTrue(matches(aliases.getValue("com.asterlink.app.link.ProtocolEntry"), "wenxi://resolve?url=x"))
        assertTrue(matches(aliases.getValue("com.asterlink.app.link.ProtocolEntry"), "wenxi://download?url=x"))
        assertFalse(matches(aliases.getValue("com.asterlink.app.link.ProtocolEntry"), "wenxi://delete?url=x"))
        assertTrue(matches(aliases.getValue("com.asterlink.app.link.ShareEntry"), "", Intent.ACTION_SEND, "text/plain"))
        assertTrue(matches(aliases.getValue("com.asterlink.app.link.SelectionEntry"), "", Intent.ACTION_PROCESS_TEXT, "text/plain"))
    }

    @Test fun disablingAllCloudsLeavesNoEntryForOrdinaryShareHyperlinks() {
        val entries = entries()
        val manager = LinkOpening(context)
        LinkOpening.targets.filter { LinkOpening.isShareEntry(it.alias) }.forEach { manager.setEnabled(it.id, false) }
        assertTrue(manager.status().filter { it["id"] !in setOf("share", "selection", "protocol") }
            .all { it["enabled"] == false })
        for (url in shareLinks.values + "https://example.test/page") {
            for (scheme in listOf("http", "https")) {
                val link = url.replace("https:", "$scheme:")
                for (mime in listOf(null, "text/html", "application/xhtml+xml")) {
                    assertEquals("Disabled link still captured: $link ($mime)", emptySet<String>(),
                        enabledMatches(entries, link, mime = mime))
                }
            }
        }
    }

    @Test fun aDisabledCloudCannotFallThroughToTheDownloaderOrPlayer() {
        val entries = entries()
        val manager = LinkOpening(context)
        for (target in LinkOpening.targets.filter { LinkOpening.isShareEntry(it.alias) }) {
            val url = shareLinks.getValue(target.entry)
            assertEquals(setOf(target.alias), enabledMatches(entries, url))
            manager.setEnabled(target.id, false)
            assertTrue("Disabled ${target.id} was captured by another entry", enabledMatches(entries, url).isEmpty())
            manager.setEnabled(target.id, true)
            assertEquals(setOf(target.alias), enabledMatches(entries, url))
        }
    }

    @Test fun cloudSwitchesKeepFilePlaybackDownloadsSharingAndProtocolsAvailable() {
        val entries = entries()
        val manager = LinkOpening(context)
        LinkOpening.targets.filter { LinkOpening.isShareEntry(it.alias) }.forEach { manager.setEnabled(it.id, false) }
        assertEquals(setOf(".DownloadEntry", ".PlayerEntry"),
            enabledMatches(entries, "https://example.test/video?id=1", mime = "video/mp4"))
        assertEquals(setOf(".PlayerEntry"), enabledMatches(entries, "content://videos.test/12", mime = "video/mp4"))
        assertEquals(setOf(".DownloadEntry"), enabledMatches(entries, "https://example.test/app.apk", mime = FileOpening.APK_MIME))
        assertEquals(setOf(".DownloadEntry"), enabledMatches(entries, "magnet:?xt=urn:btih:0123456789012345678901234567890123456789"))
        assertEquals(setOf(".DownloadEntry", "com.asterlink.app.link.ShareEntry"),
            enabledMatches(entries, "", Intent.ACTION_SEND, "text/plain"))
        assertEquals(setOf(".PlayerEntry"), enabledMatches(entries, "", Intent.ACTION_SEND, "video/mp4"))
        assertEquals(setOf("com.asterlink.app.link.SelectionEntry"),
            enabledMatches(entries, "", Intent.ACTION_PROCESS_TEXT, "text/plain"))
        assertEquals(setOf("com.asterlink.app.link.ProtocolEntry"), enabledMatches(entries, "wenxi://resolve?url=x"))
        for (id in listOf("share", "selection", "protocol")) manager.setEnabled(id, false)
        assertTrue(enabledMatches(entries, shareLinks.getValue("QuarkEntry")).isEmpty())
        assertTrue(enabledMatches(entries, "wenxi://resolve?url=x").isEmpty())
    }

    @Test fun changingOneCloudPersistsAcrossManagerInstancesAndLeavesOthersEnabled() {
        val first = LinkOpening(context)
        assertTrue(first.status().all { it["enabled"] == true })
        first.setEnabled("quark", false)
        val next = LinkOpening(context)
        assertEquals(false, next.status().single { it["id"] == "quark" }["enabled"])
        assertTrue(next.status().filter { it["id"] != "quark" }.all { it["enabled"] == true })
        next.setEnabled("quark", true)
        assertTrue(first.status().all { it["enabled"] == true })
    }

    @Test(expected = IllegalArgumentException::class) fun unknownComponentCannotBeChanged() {
        LinkOpening(context).setEnabled("MainActivity", false)
    }

    @Test fun olderAndroidOpensTheAppDetailsPageForManualAssociation() {
        LinkOpening(context).openSettings(null)
        val intent = shadowOf(context as Application).nextStartedActivity
        assertEquals(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, intent.action)
        assertEquals("package:${context.packageName}", intent.dataString)
        assertTrue(intent.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
    }
}
