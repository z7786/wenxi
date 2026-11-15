package com.asterlink.app

import android.app.Application
import android.content.Context
import android.content.res.Configuration
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.NetworkInfo
import android.os.Build
import android.os.LocaleList
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowBuild
import org.robolectric.shadows.ShadowNetworkInfo
import java.util.Locale

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 36], manifest = Config.NONE)
class ClientEnvironmentTest {
    private fun context(): Application = RuntimeEnvironment.getApplication()

    @Test fun profileUsesSystemModelAndCurrentScreenSize() {
        val context = context()
        ShadowBuild.setModel("fixture-system-phone")
        context.resources.configuration.apply {
            uiMode = Configuration.UI_MODE_TYPE_NORMAL
            smallestScreenWidthDp = 393
        }
        context.resources.displayMetrics.apply {
            density = 3f
            widthPixels = 1179
            heightPixels = 2556
        }
        val first = ClientEnvironment.read(context)
        assertEquals("fixture-system-phone", first["model"])
        assertEquals(Build.VERSION.RELEASE, first["osVersion"])
        assertEquals("phone", first["deviceType"])
        assertEquals(393, first["screenWidth"])
        assertEquals(852, first["screenHeight"])
        context.resources.displayMetrics.apply {
            widthPixels = 2556
            heightPixels = 1179
        }
        val rotated = ClientEnvironment.read(context)
        assertEquals(852, rotated["screenWidth"])
        assertEquals(393, rotated["screenHeight"])
        assertFalse(first.containsKey("serial"))
        assertFalse(first.containsKey("androidId"))
        assertFalse(first.containsKey("imei"))
    }

    @Test fun largeAndNonHandheldDevicesAreDistinguished() {
        val context = context()
        context.resources.configuration.apply {
            uiMode = Configuration.UI_MODE_TYPE_NORMAL
            smallestScreenWidthDp = 800
        }
        assertEquals("tablet", ClientEnvironment.read(context)["deviceType"])
        for ((mode, type) in mapOf(
            Configuration.UI_MODE_TYPE_TELEVISION to "television",
            Configuration.UI_MODE_TYPE_WATCH to "watch",
            Configuration.UI_MODE_TYPE_CAR to "car",
        )) {
            context.resources.configuration.uiMode = mode
            assertEquals(type, ClientEnvironment.read(context)["deviceType"])
        }
    }

    @Test fun localeTracksCurrentSystemConfiguration() {
        val context = context()
        context.resources.configuration.setLocales(LocaleList(Locale.forLanguageTag("zh-Hans-CN")))
        assertEquals("zh-Hans-CN", ClientEnvironment.read(context)["locale"])
        context.resources.configuration.setLocales(LocaleList(Locale.US))
        assertEquals("en-US", ClientEnvironment.read(context)["locale"])
    }

    @Suppress("DEPRECATION")
    @Test fun quarkTransportTracksNetworkSwitchWithoutChangingBaiduApnFields() {
        val context = context()
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val shadow = shadowOf(manager)
        fun connect(type: Int, subtype: Int, vararg transports: Int) {
            val info = ShadowNetworkInfo.newInstance(
                NetworkInfo.DetailedState.CONNECTED, type, subtype, true, true,
            )
            shadowOf(info).setExtraInfo("CMNET")
            shadow.setActiveNetworkInfo(info)
            val caps = NetworkCapabilities()
            transports.forEach { shadowOf(caps).addTransportType(it) }
            shadow.setNetworkCapabilities(manager.activeNetwork, caps)
        }

        connect(ConnectivityManager.TYPE_WIFI, 0, NetworkCapabilities.TRANSPORT_WIFI)
        val wifi = ClientEnvironment.read(context)
        assertEquals("wifi", wifi["networkTransport"])
        assertEquals("wifi", wifi["networkType"])
        assertEquals(0, wifi["networkSubtype"])
        assertFalse(wifi.containsKey("cellularSubtype"))

        for (radio in listOf(13, 20, 0)) {
            connect(ConnectivityManager.TYPE_MOBILE, radio, NetworkCapabilities.TRANSPORT_CELLULAR)
            val cellular = ClientEnvironment.read(context)
            assertEquals("cellular", cellular["networkTransport"])
            assertEquals(radio, cellular["cellularSubtype"])
            assertEquals("cmnet", cellular["networkType"])
            assertEquals(radio, cellular["networkSubtype"])
        }

        connect(ConnectivityManager.TYPE_VPN, 0, NetworkCapabilities.TRANSPORT_VPN)
        val vpn = ClientEnvironment.read(context)
        assertEquals("vpn", vpn["networkTransport"])
        assertEquals("vpn", vpn["networkType"])
        assertFalse(vpn.containsKey("cellularSubtype"))

        connect(ConnectivityManager.TYPE_VPN, 0, NetworkCapabilities.TRANSPORT_VPN, NetworkCapabilities.TRANSPORT_WIFI)
        assertEquals("wifi", ClientEnvironment.read(context)["networkTransport"])
        connect(ConnectivityManager.TYPE_VPN, 0, NetworkCapabilities.TRANSPORT_VPN, NetworkCapabilities.TRANSPORT_CELLULAR)
        val vpnCellular = ClientEnvironment.read(context)
        assertEquals("cellular", vpnCellular["networkTransport"])
        assertFalse(vpnCellular.containsKey("cellularSubtype"))
    }

    @Test fun unavailableNetworkDetailsDoNotSuppressPhoneInformation() {
        val context = context()
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        shadowOf(manager).setActiveNetworkInfo(null)
        val values = ClientEnvironment.read(context)
        assertEquals(Build.MODEL, values["model"])
        assertEquals(Build.VERSION.RELEASE, values["osVersion"])
        assertFalse(values.containsKey("networkTransport"))
        assertFalse(values.containsKey("cellularSubtype"))
    }
}
