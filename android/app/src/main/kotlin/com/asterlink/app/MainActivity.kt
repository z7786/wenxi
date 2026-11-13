package com.asterlink.app
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.os.Bundle
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import java.util.UUID

class MainActivity : FlutterActivity() {
    private val host get() = application as AsterLinkHost
    private var incomingId = UUID.randomUUID().toString()
    override fun onCreate(savedInstanceState: Bundle?) {
        incomingId = savedInstanceState?.getString("asterlink.incomingId") ?: incomingId
        host.bridge.fileOpening.restore(savedInstanceState)
        super.onCreate(savedInstanceState)
    }
    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putString("asterlink.incomingId", incomingId)
        host.bridge.fileOpening.save(outState)
    }
    override fun provideFlutterEngine(context: Context): FlutterEngine = host.engine
    override fun shouldDestroyEngineWithHost(): Boolean = false
    // Alias metadata can differ from the launcher metadata; the native inbox owns all VIEW intents.
    override fun shouldHandleDeeplinking(): Boolean = false
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        host.bridge.activity = this
        host.playback.attach(this)
        host.bridge.receiveIntent(intent, incomingId)
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        incomingId = UUID.randomUUID().toString()
        host.bridge.receiveIntent(intent, incomingId)
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (!host.bridge.activityResult(requestCode, resultCode, data)) super.onActivityResult(requestCode, resultCode, data)
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == NotificationPermission.REQUEST_CODE) host.appKeepAlive.refresh()
    }
    override fun onDestroy() {
        host.bridge.externalPlayer.dismiss(this)
        host.analytics.pause(this)
        host.playback.detach(this)
        if (host.bridge.activity === this) host.bridge.activity = null
        super.onDestroy()
    }
    override fun onResume() {
        super.onResume()
        host.playback.resumed(this)
        host.bridge.fileOpening.resumed()
        host.bridge.downloadOverlay.resumed()
        host.downloadKeepAlive.appVisible()
        host.appKeepAlive.appVisible(this)
        host.analytics.resume(this)
    }
    override fun onPause() {
        host.playback.paused(this)
        host.bridge.fileOpening.paused()
        host.analytics.pause(this)
        super.onPause()
    }
    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        host.playback.pipChanged(this, isInPictureInPictureMode)
    }
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        host.playback.configurationChanged(this)
    }
    override fun onStop() {
        host.playback.stopped(this)
        super.onStop()
    }
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) host.playback.windowFocused(this)
    }
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val handled = super.dispatchKeyEvent(event)
        when (event.keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP, KeyEvent.KEYCODE_VOLUME_DOWN, KeyEvent.KEYCODE_VOLUME_MUTE -> host.playback.volumeKey(this)
        }
        return handled
    }
}
