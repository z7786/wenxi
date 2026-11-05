package com.asterlink.app

import android.app.Activity
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.ResolveInfo
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import java.io.File
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowContentResolver

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class FileOpeningTest {
    private lateinit var context: Context
    private lateinit var activity: Activity
    private lateinit var opener: FileOpening
    private var allowed = true
    private var permissionChecks = 0
    private val results = mutableListOf<FileOpenFailure?>()
    private val uri = Uri.parse("content://file.opening.test/download/17")

    @Before fun setup() {
        context = RuntimeEnvironment.getApplication()
        activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        allowed = true
        permissionChecks = 0
        results.clear()
        ShadowContentResolver.registerProviderInternal("file.opening.test", WrongMimeProvider())
        opener = FileOpening(context, { activity }, { permissionChecks++; allowed })
    }

    private fun takeSettings(): org.robolectric.shadows.ShadowActivity.IntentForResult {
        val result = shadowOf(activity).nextStartedActivityForResult
        // Robolectric records for-result launches in a second independent queue.
        assertEquals(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, shadowOf(activity).nextStartedActivity.action)
        return result
    }

    @Test fun apkUsesInstallerMimeAndReadGrantEvenWhenProviderReportsZip() {
        opener.open(uri.toString(), "更新.APK", false, results::add)
        val launched = shadowOf(activity).nextStartedActivity
        assertEquals(Intent.ACTION_VIEW, launched.action)
        assertEquals(FileOpening.APK_MIME, launched.type)
        assertEquals(uri, launched.data)
        assertEquals(uri, launched.clipData!!.getItemAt(0).uri)
        assertTrue(launched.clipData!!.description.hasMimeType(FileOpening.APK_MIME))
        assertNotEquals(0, launched.flags and Intent.FLAG_ACTIVITY_NEW_TASK)
        assertNotEquals(0, launched.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION)
        assertEquals(0, launched.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        assertEquals(listOf<FileOpenFailure?>(null), results)
    }

    @Test fun installerReceivesAnExplicitReadGrantForItsScanner() {
        val installer = "oem.package.installer"
        val granted = mutableListOf<Pair<String, Uri>>()
        val wrapper = object : android.content.ContextWrapper(context) {
            override fun grantUriPermission(toPackage: String, uri: Uri, modeFlags: Int) {
                assertEquals(Intent.FLAG_GRANT_READ_URI_PERMISSION, modeFlags)
                granted.add(toPackage to uri)
            }
        }
        val intent = FileOpening.readableIntent(FileOpening.OpenFile(uri, FileOpening.APK_MIME), false)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        @Suppress("DEPRECATION")
        shadowOf(context.packageManager).addResolveInfoForIntent(intent, ResolveInfo().apply {
            activityInfo = ActivityInfo().apply { packageName = installer; name = "InstallerActivity" }
        })
        opener = FileOpening(wrapper, { activity }, { true })
        opener.open(uri.toString(), "app.apk", false, results::add)
        assertEquals(listOf(installer to uri), granted)
        assertEquals(uri, shadowOf(activity).nextStartedActivity.data)
    }

    @Test fun grantingUnknownSourcesContinuesTheSameInstallExactlyOnce() {
        allowed = false
        opener.open(uri.toString(), "app.apk", false, results::add)
        val settings = takeSettings()
        assertEquals(FileOpening.INSTALL_SETTINGS_REQUEST, settings.requestCode)
        assertEquals(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, settings.intent.action)
        assertEquals("package:${context.packageName}", settings.intent.data.toString())
        assertTrue(results.isEmpty())
        opener.paused()
        allowed = true
        assertTrue(opener.activityResult(settings.requestCode))
        opener.resumed()
        opener.activityResult(settings.requestCode)
        assertEquals(uri, shadowOf(activity).nextStartedActivity.data)
        assertNull(shadowOf(activity).nextStartedActivity)
        assertEquals(listOf<FileOpenFailure?>(null), results)
    }

    @Test fun cancelledAuthorizationCompletesWithAnActionableError() {
        allowed = false
        opener.open(uri.toString(), "app.apk", false, results::add)
        takeSettings()
        opener.paused()
        opener.resumed()
        assertEquals("install_permission", results.single()!!.code)
        assertNull(shadowOf(activity).nextStartedActivity)
        allowed = true
        opener.activityResult(FileOpening.INSTALL_SETTINGS_REQUEST)
        assertEquals(1, results.size)
        assertNull(shadowOf(activity).nextStartedActivity)
    }

    @Test fun sharingAnApkDoesNotRequestInstallationAuthorization() {
        allowed = false
        opener.open(uri.toString(), "app.apk", true, results::add)
        val chooser = shadowOf(activity).nextStartedActivity
        assertEquals(Intent.ACTION_CHOOSER, chooser.action)
        @Suppress("DEPRECATION")
        val shared = chooser.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)!!
        assertEquals(Intent.ACTION_SEND, shared.action)
        assertEquals(FileOpening.APK_MIME, shared.type)
        assertEquals(uri, shared.clipData!!.getItemAt(0).uri)
        assertEquals(0, permissionChecks)
        assertEquals(listOf<FileOpenFailure?>(null), results)
    }

    @Test fun ordinaryFileUsesChooserWithoutInstallPermission() {
        allowed = false
        opener.open(uri.toString(), "archive.zip", false, results::add)
        val chooser = shadowOf(activity).nextStartedActivity
        @Suppress("DEPRECATION")
        val opened = chooser.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)!!
        assertEquals(Intent.ACTION_VIEW, opened.action)
        assertEquals("application/zip", opened.type)
        assertEquals(0, permissionChecks)
    }

    @Test fun pendingInstallSurvivesActivityAndProcessRecreation() {
        allowed = false
        opener.open(uri.toString(), "app.apk", false, results::add)
        takeSettings()
        val state = Bundle()
        opener.save(state)
        // The process loses the old Dart result, but Android retains saved activity state.
        opener = FileOpening(context, { activity }, { allowed })
        opener.restore(state)
        allowed = true
        opener.resumed()
        assertEquals(uri, shadowOf(activity).nextStartedActivity.data)
        opener.activityResult(FileOpening.INSTALL_SETTINGS_REQUEST)
        assertNull(shadowOf(activity).nextStartedActivity)
    }

    @Test fun activityRecreationDoesNotOverwriteTheLiveDartCompletion() {
        allowed = false
        opener.open(uri.toString(), "app.apk", false, results::add)
        takeSettings()
        val state = Bundle()
        opener.save(state)
        opener.restore(state)
        allowed = true
        opener.activityResult(FileOpening.INSTALL_SETTINGS_REQUEST)
        assertEquals(listOf<FileOpenFailure?>(null), results)
    }

    @Test fun secondOpenCannotOverwritePendingApk() {
        allowed = false
        opener.open(uri.toString(), "app.apk", false, results::add)
        takeSettings()
        val other = mutableListOf<FileOpenFailure?>()
        opener.open("content://file.opening.test/download/18", "other.apk", false, other::add)
        assertEquals("busy", other.single()!!.code)
        allowed = true
        opener.activityResult(FileOpening.INSTALL_SETTINGS_REQUEST)
        assertEquals(uri, shadowOf(activity).nextStartedActivity.data)
        assertEquals(listOf<FileOpenFailure?>(null), results)
    }

    @Test fun absoluteAndFileUriPathsAreConvertedBeforeSharingWithAndroid() {
        val file = File(context.filesDir, "app with spaces.apk").apply { writeBytes(byteArrayOf(1)) }
        val captured = mutableListOf<File>()
        opener = FileOpening(context, { activity }, { true }, { captured.add(it); uri })
        assertEquals(uri, opener.prepare(file.absolutePath, file.name).uri)
        assertEquals(uri, opener.prepare(file.toURI().toString(), file.name).uri)
        assertEquals(listOf(file.canonicalFile, file.canonicalFile), captured)
        file.delete()
        opener.open(file.absolutePath, file.name, false, results::add)
        assertEquals("missing", results.single()!!.code)
    }

    @Test fun unsupportedLocationNeverLaunchesAnActivity() {
        opener.open("https://example.test/app.apk", "app.apk", false, results::add)
        assertEquals("location", results.single()!!.code)
        assertNull(shadowOf(activity).nextStartedActivity)
    }

    class WrongMimeProvider : ContentProvider() {
        override fun onCreate() = true
        override fun getType(uri: Uri) = "application/zip"
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
        override fun insert(uri: Uri, values: ContentValues?): Uri? = null
        override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
    }
}
