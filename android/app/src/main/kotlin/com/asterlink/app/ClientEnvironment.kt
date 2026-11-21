package com.asterlink.app

import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import java.util.Locale
import kotlin.math.roundToInt

internal object ClientEnvironment {
    @Suppress("DEPRECATION")
    fun read(context: Context): Map<String, Any> {
        val metrics = context.resources.displayMetrics
        val configuration = context.resources.configuration
        val locale = configuration.locales.let { if (it.isEmpty) Locale.getDefault() else it[0] }
        val deviceType = when {
            configuration.uiMode and Configuration.UI_MODE_TYPE_MASK == Configuration.UI_MODE_TYPE_TELEVISION ||
                context.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK) -> "television"
            configuration.uiMode and Configuration.UI_MODE_TYPE_MASK == Configuration.UI_MODE_TYPE_WATCH -> "watch"
            configuration.uiMode and Configuration.UI_MODE_TYPE_MASK == Configuration.UI_MODE_TYPE_CAR -> "car"
            configuration.smallestScreenWidthDp >= 600 -> "tablet"
            else -> "phone"
        }
        val values = mutableMapOf<String, Any>(
            "model" to Build.MODEL,
            "osVersion" to Build.VERSION.RELEASE,
            "deviceType" to deviceType,
            "screenWidth" to (metrics.widthPixels / metrics.density).roundToInt(),
            "screenHeight" to (metrics.heightPixels / metrics.density).roundToInt(),
            "locale" to locale.toLanguageTag(),
        )
        try {
            val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return values
            val network = manager.activeNetwork ?: return values
            val caps = manager.getNetworkCapabilities(network) ?: return values
            val cellular = caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
            val info = if (cellular) manager.activeNetworkInfo else null
            val quarkTransport = when {
                cellular -> "cellular"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
                else -> ""
            }
            if (quarkTransport.isNotEmpty()) values["networkTransport"] = quarkTransport
            // Keep Quark's transport and radio subtype separate from the APN
            // fields used by Baidu. VPNs may hide their underlying radio.
            if (cellular && info?.type == ConnectivityManager.TYPE_MOBILE && info.isConnected) {
                values["cellularSubtype"] = info.subtype
            }
            val type = when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                cellular -> info?.extraInfo?.lowercase(Locale.ROOT).orEmpty()
                else -> ""
            }
            if (type.isNotEmpty()) {
                values["networkType"] = type
                values["networkSubtype"] = if (cellular && type != "vpn") info?.subtype ?: 0 else 0
            }
        } catch (_: SecurityException) {
            // Restricted devices may withhold network details; omit them.
        }
        return values
    }
}
