package dev.waken.bridge_mobile

import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private val bridge get() = application as BridgeApplication

    override fun provideFlutterEngine(context: Context): FlutterEngine = bridge.engine()
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        bridge.notifications.attach(this)
        bridge.umengTestConsent.attach(this)
        bridge.notifications.captureTap(intent)
    }

    override fun onResume() {
        super.onResume()
        bridge.notifications.resumed(this)
        bridge.umengTestConsent.resumed(this)
    }

    override fun onPause() {
        bridge.umengTestConsent.paused(this)
        bridge.notifications.paused(this)
        super.onPause()
    }

    override fun onDestroy() {
        bridge.umengTestConsent.detach(this)
        bridge.notifications.detach(this)
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        bridge.notifications.captureTap(intent)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        bridge.notifications.permissionResult(requestCode)
        bridge.umengTestConsent.changed()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        bridge.umengTestConsent.changed()
        bridge.cloudPreview.changed()
    }
}
