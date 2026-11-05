package com.asterlink.app

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.nio.ByteBuffer

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class PlaybackLifecycleTest {
    private class Messenger : BinaryMessenger {
        val sent = mutableListOf<MethodCall>()
        var handler: BinaryMessenger.BinaryMessageHandler? = null
        override fun send(channel: String, message: ByteBuffer?) {
            send(channel, message, null)
        }
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            message!!.flip()
            sent.add(StandardMethodCodec.INSTANCE.decodeMethodCall(message))
            callback?.reply(StandardMethodCodec.INSTANCE.encodeSuccessEnvelope(null))
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            this.handler = handler
        }
        fun call(method: String, arguments: Map<String, Any?>) {
            val message = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method, arguments))
            message.flip()
            handler!!.onMessage(message) { response ->
                response!!.flip()
                StandardMethodCodec.INSTANCE.decodeEnvelope(response)
            }
        }
    }

    private lateinit var activity: Activity
    private lateinit var bridge: PlaybackBridge
    private lateinit var messenger: Messenger

    @Before fun setup() {
        val context: Context = RuntimeEnvironment.getApplication()
        activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        messenger = Messenger()
        bridge = PlaybackBridge(context, MethodChannel(messenger, "com.asterlink.app/playback"))
        bridge.attach(activity)
        messenger.call("begin", mapOf("session" to "test-player", "video" to true))
        messenger.sent.clear()
    }

    @After fun cleanup() { bridge.detach(activity) }

    @Test fun activityPauseReportsHiddenBeforeActivityStop() {
        bridge.paused(activity)
        val event = messenger.sent.single()
        assertEquals("action", event.method)
        val data = event.arguments as Map<*, *>
        assertEquals("test-player", data["session"])
        assertEquals("hidden", data["action"])
    }

    @Test fun visiblePictureInPictureDoesNotPauseButHiddenPlaybackDoes() {
        assertTrue(activity.enterPictureInPictureMode(PictureInPictureParams.Builder().build()))
        bridge.paused(activity)
        assertTrue(messenger.sent.isEmpty())
        bridge.stopped(activity)
        assertEquals("hidden", (messenger.sent.single().arguments as Map<*, *>)["action"])
    }

    @Test fun endedAndReplacedActivitiesCannotPauseTheCurrentSession() {
        val previous = activity
        activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        bridge.attach(activity)
        messenger.sent.clear()
        bridge.paused(previous)
        assertTrue(messenger.sent.isEmpty())
        messenger.call("end", mapOf("session" to "test-player"))
        bridge.paused(activity)
        assertTrue(messenger.sent.isEmpty())
    }
}
