package dev.waken.bridge_mobile

import android.app.Activity
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.Uri
import android.os.Build
import android.os.PersistableBundle
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal object UmengTestConsentPolicy {
    const val NOTICE_VERSION = "lenovo-upush-test-v2"

    fun eligible(debuggable: Boolean, manufacturer: String, brand: String, configured: Boolean = true): Boolean =
        configured && debuggable && (manufacturer.equals("lenovo", ignoreCase = true) || brand.equals("lenovo", ignoreCase = true))

    fun decision(eligible: Boolean, version: String?, value: String?): String =
        if (eligible && version == NOTICE_VERSION && value in setOf("accepted", "declined")) value!! else "pending"
}

class UmengTestConsent(private val app: BridgeApplication) : MethodChannel.MethodCallHandler {
    private val preferences = try {
        app.getSharedPreferences("bridge_umeng_test_consent", Context.MODE_PRIVATE)
    } catch (_: Exception) { null }
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var foreground = false
    @Volatile private var persistenceHealthy = preferences != null
    private var copiedToken: String? = null

    private val eligible: Boolean
        get() = UmengTestConsentPolicy.eligible(
            (app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0,
            Build.MANUFACTURER,
            Build.BRAND,
            BuildConfig.UMENG_PUSH_CONFIGURED,
        )

    private val interactive: Boolean
        get() = eligible && foreground && !app.notifications.permissionPromptPending &&
            activity?.let { !it.isFinishing && !it.isDestroyed && it.hasWindowFocus() } == true

    private fun decision(): String = if (!persistenceHealthy || preferences == null) "pending" else UmengTestConsentPolicy.decision(
        eligible,
        preferences.getString("notice_version", null),
        preferences.getString("decision", null),
    )

    fun hasConsent(): Boolean = try { eligible && decision() == "accepted" } catch (_: Exception) { false }

    fun bind(engine: FlutterEngine) {
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "dev.waken.bridge_mobile/umeng_test_consent")
        channel!!.setMethodCallHandler(this)
    }

    fun attach(value: Activity) { activity = value }
    fun resumed(value: Activity) {
        activity = value
        foreground = true
        app.umengPush.synchronize()
        app.umengPush.onAppStart()
        changed()
    }
    fun paused(value: Activity) { if (activity === value) { foreground = false; changed() } }
    fun detach(value: Activity) { if (activity === value) { activity = null; foreground = false; changed() } }
    fun changed() { channel?.invokeMethod("changed", null) }

    private fun state(): Map<String, Any> = mapOf(
        "eligible" to eligible,
        "interactive" to interactive,
        "noticeVersion" to UmengTestConsentPolicy.NOTICE_VERSION,
        "decision" to decision(),
        "pushStatus" to app.umengPush.status,
        "hasDeviceToken" to (app.umengPush.deviceToken != null),
    )

    private fun clearCopiedToken(token: String? = copiedToken) {
        val copied = copiedToken ?: token
        copiedToken = null
        if (copied == null) return
        try {
            val clipboard = app.getSystemService(ClipboardManager::class.java)
            val clip = clipboard.primaryClip ?: return
            if (clip.description.label == "U-Push test device token" &&
                clip.itemCount == 1 && clip.getItemAt(0).text?.toString() == copied) {
                if (Build.VERSION.SDK_INT >= 28) clipboard.clearPrimaryClip()
                else clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
            }
        } catch (_: Exception) { /* Never clear unrelated clipboard contents. */ }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "state" -> result.success(state())
                "decide" -> {
                    check(interactive)
                    val arguments = call.arguments as? Map<*, *> ?: error("Invalid decision")
                    require(arguments.keys == setOf("noticeVersion", "decision"))
                    require(arguments["noticeVersion"] == UmengTestConsentPolicy.NOTICE_VERSION)
                    val value = arguments["decision"] as? String
                    require(value == "accepted" || value == "declined")
                    val oldToken = app.umengPush.deviceToken
                    // A failed commit must not turn SharedPreferences' in-memory update into consent.
                    persistenceHealthy = false
                    if (value == "declined") {
                        clearCopiedToken(oldToken)
                        app.umengPush.withdraw()
                    }
                    check(requireNotNull(preferences).edit()
                        .putString("notice_version", UmengTestConsentPolicy.NOTICE_VERSION)
                        .putString("decision", value)
                        .commit())
                    persistenceHealthy = true
                    app.umengPush.synchronize()
                    result.success(state())
                    changed()
                }
                "copyPushToken" -> {
                    check(interactive && hasConsent())
                    val token = app.umengPush.deviceToken ?: error("No registered token")
                    val clip = ClipData.newPlainText("U-Push test device token", token)
                    if (Build.VERSION.SDK_INT >= 33) {
                        clip.description.extras = PersistableBundle().apply {
                            putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
                        }
                    }
                    app.getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
                    copiedToken = token
                    result.success(null)
                }
                "openPrivacyDetails" -> {
                    check(interactive)
                    activity!!.startActivity(Intent(Intent.ACTION_VIEW,
                        Uri.parse("https://developer.umeng.com/docs/147377/detail/210156")))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (_: Exception) {
            if (!hasConsent()) clearCopiedToken()
            app.umengPush.synchronize()
            result.error("umeng_test_consent_unavailable", "Test consent operation unavailable", null)
        }
    }
}
