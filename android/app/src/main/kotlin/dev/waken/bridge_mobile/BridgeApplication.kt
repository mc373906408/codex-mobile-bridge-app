package dev.waken.bridge_mobile

import android.app.Application
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor

class BridgeApplication : Application() {
    private external fun initializeTls(context: Context)
    lateinit var notifications: BridgeNotifications
        private set
    lateinit var umengTestConsent: UmengTestConsent
        private set
    internal lateinit var umengPush: UmengPushSession
        private set
    private var sharedEngine: FlutterEngine? = null

    internal fun hasUmengPushConsent(): Boolean =
        this::umengTestConsent.isInitialized && umengTestConsent.hasConsent()

    override fun onCreate() {
        super.onCreate()
        System.loadLibrary("bridge_native")
        initializeTls(applicationContext)
        notifications = BridgeNotifications(this)
        umengTestConsent = UmengTestConsent(this)
        umengPush = UmengPushSession(
            UmengPushSdk(this) { umengTestConsent.hasConsent() },
            { umengTestConsent.hasConsent() },
            { umengTestConsent.changed() },
        )
        umengPush.synchronize()
    }

    fun engine(): FlutterEngine = sharedEngine ?: FlutterEngine(this).also { engine ->
        // The foreground service and Activity share one repository and secure credential writer.
        sharedEngine = engine
        notifications.bind(engine)
        umengTestConsent.bind(engine)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
    }
}
