package dev.waken.bridge_mobile

import android.content.Context

internal object CloudNotificationConsentPolicy {
    fun notice(production: Boolean) = if (production) "cloud-umeng-push-v1" else "cloud-notifications-v1"
    fun accepted(production: Boolean, version: String?, decision: String?): Boolean =
        version == notice(production) && decision == "accepted"
}

/** Separate from the Lenovo trial. A failed durable save never grants in-memory consent. */
class CloudNotificationConsent(private val app: BridgeApplication) {
    private val preferences = runCatching {
        app.getSharedPreferences("bridge_cloud_notification_consent", Context.MODE_PRIVATE)
    }.getOrNull()
    @Volatile private var healthy = preferences != null
    @Volatile var revision = 0L
        private set
    val noticeVersion get() = CloudNotificationConsentPolicy.notice(BuildConfig.UMENG_PUSH_PRODUCTION)

    fun hasConsent(): Boolean = runCatching {
        healthy && preferences != null && CloudNotificationConsentPolicy.accepted(
            BuildConfig.UMENG_PUSH_PRODUCTION,
            preferences.getString("notice_version", null), preferences.getString("decision", null))
    }.getOrDefault(false)

    fun decide(enabled: Boolean, version: String) {
        check(app.notifications.canChangeCloudConsent)
        require(version == noticeVersion)
        healthy = false
        ++revision
        if (!enabled) {
            if (BuildConfig.UMENG_PUSH_PRODUCTION) app.umengPush.withdraw()
            app.cloudPreview.withdraw()
        }
        check(requireNotNull(preferences).edit().putString("notice_version", noticeVersion)
            .putString("decision", if (enabled) "accepted" else "declined").commit())
        healthy = true
        if (BuildConfig.UMENG_PUSH_PRODUCTION) app.umengPush.synchronize()
        app.cloudPreview.changed()
    }
}
