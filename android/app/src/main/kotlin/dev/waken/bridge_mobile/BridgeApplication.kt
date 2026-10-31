package dev.waken.bridge_mobile

import android.app.Application
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor

class BridgeApplication : Application() {
    private external fun initializeTls(context: Context)
    lateinit var notifications: BridgeNotifications
        private set
    lateinit var cloudPreview: CloudPreview
        private set
    lateinit var cloudConsent: CloudNotificationConsent
        private set
    lateinit var umengTestConsent: UmengTestConsent
        private set
    internal lateinit var umengPush: UmengPushSession
        private set
    private var sharedEngine: FlutterEngine? = null

    internal fun hasUmengPushConsent(): Boolean =
        if (BuildConfig.UMENG_PUSH_PRODUCTION) this::cloudConsent.isInitialized && cloudConsent.hasConsent()
        else this::umengTestConsent.isInitialized && umengTestConsent.hasConsent()

    override fun onCreate() {
        super.onCreate()
        System.loadLibrary("bridge_native")
        initializeTls(applicationContext)
        notifications = BridgeNotifications(this)
        cloudConsent = CloudNotificationConsent(this)
        cloudPreview = CloudPreview(this)
        umengTestConsent = UmengTestConsent(this)
        umengPush = UmengPushSession(
            UmengPushSdk(this) { hasUmengPushConsent() },
            { hasUmengPushConsent() },
            { umengTestConsent.changed(); cloudPreview.changed() },
        )
        umengPush.synchronize()
    }

    fun engine(): FlutterEngine = sharedEngine ?: FlutterEngine(this).also { engine ->
        // The foreground service and Activity share one repository and secure credential writer.
        sharedEngine = engine
        notifications.bind(engine)
        cloudPreview.bind(engine)
        umengTestConsent.bind(engine)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
    }
}
