package dev.waken.bridge_mobile

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale
import java.util.UUID

class BridgeNotifications(private val app: BridgeApplication) : MethodChannel.MethodCallHandler {
    companion object {
        const val LISTENER_ID = 4100
        const val EVENT_ID = 4101
        const val TEST_ID = 4102
        private const val OPEN = "dev.waken.bridge_mobile.OPEN_NOTIFICATION"
        private const val PERMISSION_REQUEST = 4103
        private const val EVENTS = "bridge.events.v1"
        private const val LISTENER = "bridge.listener.v1"
    }

    private val preferences = app.getSharedPreferences("bridge_notifications", Context.MODE_PRIVATE)
    private val manager = app.getSystemService(NotificationManager::class.java)
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var foreground = false
    private var initialized = false
    private var starting = false
    private var permissionInFlight = false
    private var permissionReply: MethodChannel.Result? = null
    private var permissionResolved = false
    private var pendingTap: Map<String, String>? = null
    private var online = 0
    private var total = 0
    private var wakeLock: PowerManager.WakeLock? = null
    var running = false
        private set
    val permissionPromptPending: Boolean get() = permissionInFlight

    init {
        // The retired app toggle must not keep upgraded installations silent.
        if (preferences.contains("enabled")) preferences.edit().remove("enabled").apply()
    }

    fun bind(engine: FlutterEngine) {
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "dev.waken.bridge_mobile/notifications")
        channel!!.setMethodCallHandler(this)
    }

    fun attach(value: Activity) { activity = value }
    fun detach(value: Activity) {
        if (activity === value) {
            activity = null
            foreground = false
        }
    }
    fun paused(value: Activity) {
        if (activity === value) foreground = false
    }
    fun resumed(value: Activity) {
        activity = value
        foreground = true
        channels()
        finishPermissionRequest()
        try { ensureListening() } catch (_: RuntimeException) { /* The settings screen reports not running. */ }
        changed()
    }

    fun serviceState(value: Boolean) {
        starting = false
        running = value
        renewWakeLease()
        changed()
    }

    private fun renewWakeLease() {
        if (!running || preferences.getStringSet("computers", emptySet()).isNullOrEmpty()) {
            wakeLock?.let { if (it.isHeld) it.release() }
            return
        }
        val lock = wakeLock ?: app.getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "bridge:notification-listener")
            .also { it.setReferenceCounted(false); wakeLock = it }
        // A stalled Dart listener cannot hold the CPU indefinitely. Doze/OEM limits still apply.
        lock.acquire(90_000L)
    }

    private fun changed() { channel?.invokeMethod("changed", null) }

    private fun text(id: Int): String {
        val configuration = Configuration(app.resources.configuration)
        configuration.setLocale(Locale.forLanguageTag(preferences.getString("locale", "zh") ?: "zh"))
        return app.createConfigurationContext(configuration).getString(id)
    }

    private fun channels() {
        manager.createNotificationChannel(NotificationChannel(EVENTS, text(R.string.notification_events), NotificationManager.IMPORTANCE_HIGH).apply {
            description = text(R.string.notification_events_description)
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        })
        manager.createNotificationChannel(NotificationChannel(LISTENER, text(R.string.notification_listener), NotificationManager.IMPORTANCE_LOW).apply {
            setSound(null, null)
            enableVibration(false)
            setShowBadge(false)
        })
    }

    private fun allowed(): Boolean = manager.areNotificationsEnabled() &&
        manager.getNotificationChannel(EVENTS)?.importance != NotificationManager.IMPORTANCE_NONE &&
        manager.getNotificationChannel(LISTENER)?.importance != NotificationManager.IMPORTANCE_NONE

    private fun state(): Map<String, Boolean> {
        channels()
        if (!allowed()) suspendListening()
        val power = app.getSystemService(PowerManager::class.java)
        return mapOf("allowed" to allowed(), "running" to running,
            "batteryOptimized" to !power.isIgnoringBatteryOptimizations(app.packageName))
    }

    fun canListen(): Boolean = initialized && allowed()

    private fun ensureListening() {
        if (!initialized || !foreground || activity == null) return
        channels()
        if (allowed()) {
            if (!running && !starting) start()
        } else {
            suspendListening()
            if (needsPermission() && !preferences.getBoolean("permission_requested", false)) {
                requestPermission(null)
            }
        }
    }

    private fun start() {
        check(foreground && activity != null) { "Foreground Activity required" }
        starting = true
        try {
            app.startForegroundService(Intent(app, NotificationListenerService::class.java))
        } catch (error: RuntimeException) {
            starting = false
            throw error
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "state" -> result.success(state())
                "ensureListening" -> {
                    initialized = true
                    ensureListening()
                    result.success(null)
                }
                "requestPermission" -> requestPermission(result)
                "configure" -> {
                    val computers = call.argument<List<String>>("computers")?.toSet() ?: emptySet()
                    val locale = if (call.argument<String>("locale") == "en") "en" else "zh"
                    check(preferences.edit().putStringSet("computers", computers).putString("locale", locale).commit())
                    retainTargets { computers.contains(it.optString("computerId")) }
                    channels()
                    renewWakeLease()
                    updateOngoing()
                    result.success(null)
                }
                "readLedger" -> result.success(preferences.getString("ledger", null))
                "writeLedger" -> {
                    val value = call.arguments as String
                    require(value.length <= 2_000_000)
                    check(preferences.edit().putString("ledger", value).commit())
                    result.success(null)
                }
                "clearComputer" -> {
                    retainTargets { it.optString("computerId") != call.arguments as String }
                    result.success(null)
                }
                "showEvent" -> result.success(showEvent(call))
                "updateStatus" -> {
                    online = call.argument<Int>("online") ?: 0
                    total = call.argument<Int>("total") ?: 0
                    if (!allowed()) suspendListening() else {
                        renewWakeLease()
                        updateOngoing()
                    }
                    result.success(null)
                }
                "test" -> {
                    if (!allowed()) result.success(false) else {
                        manager.notify(TEST_ID, Notification.Builder(app, EVENTS)
                            .setSmallIcon(R.drawable.ic_notification)
                            .setContentTitle(text(R.string.notification_test))
                            .setContentText(text(R.string.notification_test_body))
                            .setContentIntent(homeIntent()).setAutoCancel(true).build())
                        result.success(true)
                    }
                }
                "settings" -> {
                    val host = activity ?: error("No Activity")
                    val intent = if (call.argument<Boolean>("battery") == true) {
                        Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                    } else {
                        Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, app.packageName)
                    }
                    host.startActivity(intent)
                    result.success(null)
                }
                "takeTap" -> {
                    result.success(pendingTap)
                    pendingTap = null
                }
                else -> result.notImplemented()
            }
        } catch (_: Exception) {
            result.error("notifications_unavailable", "Notification operation unavailable", null)
        }
    }

    private fun needsPermission(): Boolean = Build.VERSION.SDK_INT >= 33 &&
        app.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED

    private fun requestPermission(result: MethodChannel.Result?) {
        channels()
        val host = activity
        if (host == null || !foreground) { result?.success(false); return }
        if (needsPermission()) {
            if (permissionInFlight) { result?.success(false); return }
            // Remember denials/dismissals across restarts; only an explicit test may ask again.
            check(preferences.edit().putBoolean("permission_requested", true).commit())
            permissionInFlight = true
            permissionReply = result
            try {
                host.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST)
            } catch (error: RuntimeException) {
                permissionInFlight = false
                permissionReply = null
                throw error
            }
        } else result?.success(allowed())
    }

    fun permissionResult(requestCode: Int) {
        if (requestCode != PERMISSION_REQUEST) return
        permissionResolved = true
        finishPermissionRequest()
        try { ensureListening() } catch (_: RuntimeException) { /* Retry on the next foreground resume. */ }
        changed()
    }

    private fun finishPermissionRequest() {
        // Android can report a grant before resuming the Activity that may start the service.
        if (!permissionResolved || !foreground) return
        permissionReply?.success(allowed())
        permissionReply = null
        permissionInFlight = false
        permissionResolved = false
    }

    private fun suspendListening() {
        if (running || starting) app.stopService(Intent(app, NotificationListenerService::class.java))
        starting = false
    }

    private fun targets(): List<JSONObject> = try {
        val array = JSONArray(preferences.getString("targets", "[]"))
        (0 until array.length()).mapNotNull { array.optJSONObject(it) }
    } catch (_: Exception) { emptyList() }

    private fun saveTargets(values: List<JSONObject>) {
        check(preferences.edit().putString("targets", JSONArray(values).toString()).commit())
    }

    private fun retainTargets(keep: (JSONObject) -> Boolean) {
        val values = targets()
        val retained = values.filter(keep)
        values.filterNot(keep).forEach { manager.cancel(it.optString("token"), EVENT_ID) }
        saveTargets(retained)
    }

    private fun showEvent(call: MethodCall): Boolean {
        if (!allowed()) { suspendListening(); return false }
        if (!running) return false
        fun field(key: String) = (call.argument<String>(key) ?: error("Missing field")).also {
            require(it.isNotEmpty() && it.length <= 256)
        }
        val computer = field("computerId")
        if (!preferences.getStringSet("computers", emptySet())!!.contains(computer)) return false
        val scope = field("scope")
        val event = field("eventId")
        val kind = field("kind")
        require(kind == "request" || kind == "completion")
        val values = targets().toMutableList()
        if (values.any { it.optString("computerId") == computer && it.optString("scope") == scope && it.optString("eventId") == event }) return true
        val token = UUID.randomUUID().toString()
        val target = JSONObject().put("token", token).put("computerId", computer).put("scope", scope).put("eventId", event)
        val intent = Intent(app, MainActivity::class.java).setAction(OPEN)
            .setData(Uri.parse("bridge-notification://open/$token"))
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pending = PendingIntent.getActivity(app, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val name = (call.argument<String>("computerName") ?: "Bridge").take(80)
        val notification = Notification.Builder(app, EVENTS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(text(if (kind == "request") R.string.notification_request else R.string.notification_completion))
            .setContentText("$name - ${text(R.string.notification_open)}")
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(Notification.Builder(app, EVENTS).setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("Bridge").setContentText(text(R.string.notification_private)).build())
            .setContentIntent(pending).setOnlyAlertOnce(true).setAutoCancel(true).build()
        // Persist only an opaque route. Tapping must resolve the event under fresh gateway auth.
        values.add(target)
        while (values.size > 20) manager.cancel(values.removeAt(0).optString("token"), EVENT_ID)
        saveTargets(values)
        try {
            manager.notify(token, EVENT_ID, notification)
        } catch (error: RuntimeException) {
            saveTargets(values.filter { it !== target })
            throw error
        }
        return true
    }

    fun captureTap(intent: Intent?) {
        if (intent?.action != OPEN) return
        val uri = intent.data ?: return
        if (uri.scheme != "bridge-notification" || uri.host != "open") return
        val token = uri.lastPathSegment ?: return
        // MainActivity is exported; never trust arbitrary route extras from another app.
        val values = targets()
        val target = values.firstOrNull { it.optString("token") == token && !it.optBoolean("opened") } ?: return
        target.put("opened", true)
        if (runCatching { saveTargets(values) }.isFailure) return
        pendingTap = listOf("computerId", "scope", "eventId").associateWith { target.getString(it) }
        manager.cancel(token, EVENT_ID)
        intent.action = Intent.ACTION_MAIN
        intent.data = null
        channel?.invokeMethod("tap", null)
    }

    private fun homeIntent(): PendingIntent = PendingIntent.getActivity(app, 0,
        Intent(app, MainActivity::class.java).setAction(Intent.ACTION_MAIN)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    fun ongoingNotification(): Notification {
        channels()
        val body = if (total == 0) text(R.string.notification_connecting)
            else "${text(R.string.notification_connections)} $online/$total"
        return Notification.Builder(app, LISTENER).setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(text(R.string.notification_listening)).setContentText(body)
            .setContentIntent(homeIntent()).setOngoing(true).setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE).build()
    }

    private fun updateOngoing() {
        if (running) manager.notify(LISTENER_ID, ongoingNotification())
    }
}
