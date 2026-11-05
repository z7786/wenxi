package com.asterlink.app

import android.app.Activity
import android.app.AlertDialog
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.ApplicationInfo
import android.content.pm.ResolveInfo
import android.net.Uri
import android.os.Looper
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowAlertDialog
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class ExternalPlayerOpeningTest {
    private lateinit var context: Context
    private lateinit var activity: Activity
    private lateinit var opening: ExternalPlayerOpening
    private val results = mutableListOf<Pair<Boolean, FileOpenFailure?>>()
    private val video = "http://127.0.0.1:39212/session/video"

    @Before fun setup() {
        context = RuntimeEnvironment.getApplication()
        activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        opening = ExternalPlayerOpening(context, { activity }, FileOpening(context, { activity }))
        context.getSharedPreferences("external-player-history", Context.MODE_PRIVATE).edit().clear().commit()
        results.clear()
    }

    private fun player(packageName: String, name: String = "PlayerActivity", label: String = packageName) = ResolveInfo().apply {
        activityInfo = ActivityInfo().apply {
            this.packageName = packageName
            this.name = name
            exported = true
            enabled = true
            applicationInfo = ApplicationInfo().apply {
                this.packageName = packageName
                nonLocalizedLabel = label
                enabled = true
            }
        }
        nonLocalizedLabel = label
    }

    private fun installed(vararg players: ResolveInfo) {
        val intent = opening.prepare(video, "movie.mp4", 0)
        for (player in players) shadowOf(context.packageManager).addResolveInfoForIntent(intent, player)
    }

    private fun open() = opening.open(video, "movie.mp4", 43210) { success, error -> results.add(success to error) }

    @Test fun onlyExportedEnabledThirdPartyPlayersAreOfferedAndDuplicateActivitiesCollapse() {
        val hidden = player("hidden.player").apply { activityInfo.exported = false }
        val disabled = player("disabled.player").apply { activityInfo.enabled = false }
        installed(player(context.packageName), player("vlc.player"), player("vlc.player", "Alias"), hidden, disabled)
        val targets = opening.targets(opening.prepare(video, "movie.mp4", 0))
        assertEquals(listOf("vlc.player"), targets.map { it.activityInfo.packageName })
    }

    @Test fun choiceLaunchesTheSelectedComponentWithTheCurrentVideoAndPosition() {
        installed(player("fixture.player", label = "Fixture Player"))
        open()
        assertTrue(results.isEmpty())
        val dialog = ShadowAlertDialog.getLatestAlertDialog()
        assertEquals("选择第三方播放器", shadowOf(dialog).title.toString())
        dialog.listView.performItemClick(null, 0, 0)
        shadowOf(Looper.getMainLooper()).idle()
        val intent = shadowOf(activity).nextStartedActivity
        assertEquals(Intent.ACTION_VIEW, intent.action)
        assertEquals(ComponentName("fixture.player", "PlayerActivity"), intent.component)
        assertEquals(video, intent.data.toString())
        assertEquals("video/mp4", intent.type)
        assertEquals("movie.mp4", intent.getStringExtra("title"))
        assertEquals(43210, intent.getIntExtra("position", -1))
        assertEquals(43210L, intent.getLongExtra("extra_start_time", -1))
        assertEquals(listOf(true to null), results)
    }

    @Test fun cancellingOrDestroyingTheChooserCompletesOnceWithoutLaunchingAnyApp() {
        installed(player("fixture.player"))
        open()
        val dialog = ShadowAlertDialog.getLatestAlertDialog()
        dialog.getButton(AlertDialog.BUTTON_NEGATIVE).performClick()
        shadowOf(Looper.getMainLooper()).idle()
        opening.dismiss(activity)
        assertEquals(listOf(false to null), results)
        assertNull(shadowOf(activity).nextStartedActivity)
        results.clear()
        open()
        opening.dismiss(activity)
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(listOf(false to null), results)
    }

    @Test fun noInstalledPlayerProducesAnActionableErrorInsteadOfOpeningItself() {
        installed(player(context.packageName))
        open()
        assertFalse(results.single().first)
        assertEquals("no_player", results.single().second!!.code)
        assertNull(shadowOf(activity).nextStartedActivity)
    }

    @Test fun localFilesUseFileProviderAndReadOnlyClipDataGrants() {
        val content = Uri.parse("content://fixture.files/video/1")
        val file = File(context.filesDir, "movie.mp4").apply { writeBytes(byteArrayOf(1)) }
        val files = FileOpening(context, { activity }, localUri = { content })
        opening = ExternalPlayerOpening(context, { activity }, files)
        for (path in listOf(file.absolutePath, file.toURI().toString(), content.toString())) {
            val intent = opening.prepare(path, "movie.mp4", 0)
            assertEquals(content, intent.data)
            assertEquals(content, intent.clipData!!.getItemAt(0).uri)
            assertNotEquals(0, intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION)
            assertEquals(0, intent.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        }
    }

    @Test fun hlsTransportTypeTakesPrecedenceOverTheOriginalCloudFilename() {
        val intent = opening.prepare("http://127.0.0.1:39212/session/index.m3u8", "movie.mp4", -5)
        assertEquals("application/vnd.apple.mpegurl", intent.type)
        assertEquals(0, intent.getIntExtra("position", -1))
    }

    @Test fun repeatedSelectionDismissesBeforeLaunchAndKeepsMultipleRecentPlayers() {
        installed(player("alpha.player"), player("beta.player"), player("gamma.player"))
        for (wanted in listOf("beta.player", "gamma.player", "alpha.player", "beta.player")) {
            open()
            val chooser = ShadowAlertDialog.getLatestAlertDialog()
            val offered = opening.targets(opening.prepare(video, "movie.mp4", 0))
            val index = offered.indexOfFirst { it.activityInfo.packageName == wanted }
            chooser.listView.performItemClick(null, index, index.toLong())
            shadowOf(Looper.getMainLooper()).idle()
            assertFalse(chooser.isShowing)
            assertEquals(wanted, shadowOf(activity).nextStartedActivity.component!!.packageName)
            assertEquals(true to null, results.last())
        }
        assertEquals(4, results.size)
        assertEquals(listOf("beta.player", "alpha.player", "gamma.player"),
            opening.targets(opening.prepare(video, "movie.mp4", 0)).map { it.activityInfo.packageName })
        open()
        val chooser = ShadowAlertDialog.getLatestAlertDialog()
        chooser.getButton(AlertDialog.BUTTON_NEGATIVE).performClick()
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(false to null, results.last())
        assertEquals(5, results.size)
    }
}
