package com.asterlink.app

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import com.google.zxing.client.android.Intents
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ActivityController
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class LanQrScannerTest {
    private lateinit var controller: ActivityController<Activity>
    private lateinit var activity: Activity
    private lateinit var scanner: LanQrScanner

    private class Reply : MethodChannel.Result {
        var calls = 0
        var value: Any? = null
        var error: String? = null
        var errorMessage: String? = null
        override fun success(result: Any?) { calls++; value = result }
        override fun error(code: String, message: String?, details: Any?) { calls++; error = code; errorMessage = message }
        override fun notImplemented() { error("not implemented") }
    }

    @Before fun setup() {
        controller = Robolectric.buildActivity(Activity::class.java).setup()
        activity = controller.get()
        shadowOf(activity.packageManager).setSystemFeature(PackageManager.FEATURE_CAMERA_ANY, true)
        scanner = LanQrScanner { activity }
    }

    @After fun cleanup() { controller.pause().stop().destroy() }

    @Test fun usesPrivateOfflineScannerWithoutSavingCameraImages() {
        scanner.scan(Reply())
        val request = shadowOf(activity).nextStartedActivityForResult
        assertEquals(LanQrScanner.REQUEST_CODE, request.requestCode)
        assertEquals(LanQrScanActivity::class.java.name, request.intent.component!!.className)
        assertEquals("QR_CODE", request.intent.getStringExtra(Intents.Scan.FORMATS))
        assertFalse(request.intent.getBooleanExtra(Intents.Scan.ORIENTATION_LOCKED, true))
        assertFalse(request.intent.getBooleanExtra(Intents.Scan.BARCODE_IMAGE_ENABLED, true))
        assertFalse(request.intent.getBooleanExtra(Intents.Scan.SHOW_MISSING_CAMERA_PERMISSION_DIALOG, true))
    }

    @Test fun cancellationCompletesOnceAndAllowsAnotherScan() {
        val first = Reply()
        scanner.scan(first)
        assertFalse(scanner.activityResult(831, Activity.RESULT_OK, null))
        assertEquals(0, first.calls)
        scanner.activityResult(LanQrScanner.REQUEST_CODE, Activity.RESULT_CANCELED, null)
        assertEquals(1, first.calls)
        assertNull(first.error)
        assertNull(first.value)
        scanner.activityResult(LanQrScanner.REQUEST_CODE, Activity.RESULT_CANCELED, null)
        assertEquals(1, first.calls)
        val next = Reply()
        scanner.scan(next)
        val payload = "http://192.168.1.10:52381/s/11111111111111111111111111111111"
        scanner.activityResult(LanQrScanner.REQUEST_CODE, Activity.RESULT_OK, Intent().putExtra(Intents.Scan.RESULT, payload))
        assertEquals(payload, next.value)
        assertEquals(1, next.calls)
    }

    @Test fun parseScannerKeepsShareContentAndUsesItsOwnPresentation() {
        val reply = Reply()
        scanner.scan(reply, parseShare = true)
        val request = shadowOf(activity).nextStartedActivityForResult
        assertTrue(request.intent.getBooleanExtra(LanQrScanner.PARSE_QR_EXTRA, false))
        val payload = "分享 https://pan.quark.cn/s/Abc 提取码：a123 " + "内容".repeat(1100)
        scanner.activityResult(LanQrScanner.REQUEST_CODE, Activity.RESULT_OK,
            Intent().putExtra(Intents.Scan.RESULT, payload))
        assertEquals(payload, reply.value)
        val connection = Reply()
        scanner.scan(connection)
        val next = shadowOf(activity).nextStartedActivityForResult
        assertFalse(next.intent.getBooleanExtra(LanQrScanner.PARSE_QR_EXTRA, true))
        scanner.activityResult(LanQrScanner.REQUEST_CODE, Activity.RESULT_OK,
            Intent().putExtra(Intents.Scan.RESULT, payload))
        assertEquals("qr_invalid", connection.error)
    }

    @Test fun parsePermissionFailureOffersImageRecognitionAndReleasesRequest() {
        val denied = Reply()
        scanner.scan(denied, parseShare = true)
        scanner.activityResult(LanQrScanner.REQUEST_CODE, Activity.RESULT_CANCELED,
            Intent().putExtra(Intents.Scan.MISSING_CAMERA_PERMISSION, true))
        assertEquals("qr_permission", denied.error)
        assertTrue(denied.errorMessage!!.contains("图片"))
        val next = Reply()
        scanner.scan(next, parseShare = true)
        scanner.activityResult(LanQrScanner.REQUEST_CODE, Activity.RESULT_OK,
            Intent().putExtra(Intents.Scan.RESULT, "x".repeat(16385)))
        assertEquals("qr_invalid", next.error)
        val command = Reply()
        scanner.scan(command, parseShare = true)
        scanner.activityResult(LanQrScanner.REQUEST_CODE, Activity.RESULT_OK,
            Intent().putExtra(Intents.Scan.RESULT, "/*391R8TRNLu2U:/"))
        assertEquals("/*391R8TRNLu2U:/", command.value)
    }

    @Test fun permissionDenialIsReportedAndDoesNotLeaveScannerBusy() {
        val denied = Reply()
        scanner.scan(denied)
        scanner.activityResult(LanQrScanner.REQUEST_CODE, Activity.RESULT_CANCELED,
            Intent().putExtra(Intents.Scan.MISSING_CAMERA_PERMISSION, true))
        assertEquals("qr_permission", denied.error)
        val next = Reply()
        scanner.scan(next)
        assertEquals(0, next.calls)
        scanner.activityResult(LanQrScanner.REQUEST_CODE, Activity.RESULT_OK,
            Intent().putExtra(Intents.Scan.RESULT, "x".repeat(2049)))
        assertEquals("qr_invalid", next.error)
    }

    @Test fun duplicateRequestDoesNotReplaceThePendingCallback() {
        val first = Reply()
        scanner.scan(first)
        val other = Reply()
        scanner.scan(other)
        assertEquals("qr_busy", other.error)
        assertEquals(0, first.calls)
        scanner.activityResult(LanQrScanner.REQUEST_CODE, Activity.RESULT_CANCELED, null)
        assertEquals(1, first.calls)
    }

    @Test fun unavailableCameraOrActivityLeavesManualConnectionUsable() {
        val missingActivity = Reply()
        LanQrScanner { null }.scan(missingActivity)
        assertEquals("qr_busy", missingActivity.error)
        shadowOf(activity.packageManager).setSystemFeature(PackageManager.FEATURE_CAMERA_ANY, false)
        val missingCamera = Reply()
        scanner.scan(missingCamera)
        assertEquals("qr_camera", missingCamera.error)
        assertNull(shadowOf(activity).nextStartedActivityForResult)
    }
}
