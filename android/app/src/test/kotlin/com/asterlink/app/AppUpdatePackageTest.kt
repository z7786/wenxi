package com.asterlink.app

import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.Signature
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [27], manifest = Config.NONE)
class AppUpdatePackageTest {
    @Test fun preparesUpdatesOutsidePrivateCacheWhenExternalCacheIsAvailable() {
        val context = RuntimeEnvironment.getApplication()
        val folder = AppUpdatePackage.updateFolder(context)
        assertEquals(File(context.externalCacheDir, "app_updates").canonicalFile, folder.canonicalFile)
        assertTrue(folder.isDirectory)
    }

    @Test fun stagedPackagePreservesAllBytesAndRejectsTruncatedCopies() {
        val folder = AppUpdatePackage.updateFolder(RuntimeEnvironment.getApplication())
        val copy = File.createTempFile("update-test-", ".apk", folder)
        val bytes = ByteArray(180000) { (it % 251).toByte() }
        try {
            AppUpdatePackage.copyPackage(ByteArrayInputStream(bytes), copy, bytes.size.toLong())
            assertArrayEquals(bytes, copy.readBytes())
            // A document provider may leave SIZE unknown even though its stream is complete.
            AppUpdatePackage.copyPackage(ByteArrayInputStream(bytes), copy, 0)
            assertArrayEquals(bytes, copy.readBytes())
            try {
                AppUpdatePackage.copyPackage(ByteArrayInputStream(bytes.copyOf(2048)), copy, bytes.size.toLong())
                fail("Truncated APK accepted")
            } catch (error: IOException) {
                assertTrue(error.message.orEmpty().contains("不完整"))
                assertFalse(copy.exists())
            }
        } finally { copy.delete() }
    }

    @Suppress("DEPRECATION")
    private fun pkg(build: Int = 120, version: String = "1.2.0", name: String = "com.asterlink.app", signer: String = "abcd") =
        PackageInfo().apply {
            packageName = name
            versionCode = build
            versionName = version
            signatures = arrayOf(Signature(signer))
            applicationInfo = ApplicationInfo().apply { minSdkVersion = 23 }
        }

    private fun rejected(candidate: PackageInfo, expected: String) {
        try {
            AppUpdatePackage.validate(candidate, pkg(110, "1.1.0"), "1.2.0", 120)
            fail("Invalid update was accepted")
        } catch (error: IllegalArgumentException) {
            assertTrue(error.message.orEmpty(), error.message.orEmpty().contains(expected))
        }
    }

    @Test fun acceptsSamePackageNewerBuildAndMatchingSignature() {
        AppUpdatePackage.validate(pkg(), pkg(110, "1.1.0"), "1.2.0", 120)
    }

    @Test fun githubVersionWithoutBuildStillRequiresANewerSignedPackage() {
        AppUpdatePackage.validate(pkg(), pkg(110, "1.1.0"), "v1.2.0", 0)
    }

    @Test fun rejectsWrongPackage() { rejected(pkg(name = "other.application"), "包名") }
    @Test fun rejectsOldBuild() { rejected(pkg(build = 110), "不是更新") }
    @Test fun rejectsUnexpectedBuild() { rejected(pkg(build = 121), "构建号") }
    @Test fun rejectsUnexpectedVersion() { rejected(pkg(version = "1.3.0"), "版本") }
    @Test fun rejectsDifferentSigningKey() { rejected(pkg(signer = "1234"), "签名") }
    @Suppress("DEPRECATION")
    @Test fun rejectsUnsignedPackage() { rejected(pkg().apply { signatures = emptyArray() }, "签名") }
    @Test fun rejectsUnsupportedSystem() { rejected(pkg().apply { applicationInfo!!.minSdkVersion = 30 }, "Android") }
}
