package dev.waken.bridge_mobile

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Preview keys and receipt metadata only. Cold delivery never creates a Flutter engine. */
class CloudPreview(private val app: BridgeApplication) : MethodChannel.MethodCallHandler {
    private val preferences = app.getSharedPreferences("bridge_cloud_preview", Context.MODE_PRIVATE)
    private var channel: MethodChannel? = null
    private external fun decrypt(credentials: String, envelope: String, now: Long): String?

    init { System.loadLibrary("bridge_preview") }

    fun bind(engine: FlutterEngine) {
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "dev.waken.bridge_mobile/cloud_push")
        channel!!.setMethodCallHandler(this)
    }
    fun changed() { channel?.invokeMethod("changed", null) }
    @Synchronized fun withdraw() {
        app.notifications.clearCloudNotifications()
        val edit = preferences.edit()
        preferences.all.keys.filter { it.startsWith("scope:") }.forEach { edit.remove(it) }
        check(edit.commit())
        changed()
    }
    private fun state() = mapOf("supported" to true, "configured" to BuildConfig.UMENG_PUSH_CONFIGURED,
        "allowed" to app.notifications.cloudAllowed(), "consent" to app.cloudConsent.hasConsent(),
        "interactive" to app.notifications.canChangeCloudConsent, "noticeVersion" to app.cloudConsent.noticeVersion,
        "pushStatus" to app.umengPush.status, "platform" to "umeng", "appId" to BuildConfig.UMENG_PUSH_APP_KEY,
        "token" to (if (app.cloudConsent.hasConsent()) app.umengPush.deviceToken ?: "" else ""))
    private fun now() = System.currentTimeMillis() / 1000
    private fun field(value: String) = value.also { require(it.isNotEmpty() && it.length <= 256) }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(KEY, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(KEY, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
        }.generateKey()
    }
    private fun seal(computer: String, raw: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        cipher.updateAAD(computer.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(cipher.iv + cipher.doFinal(raw.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
    }
    private fun open(computer: String): String? {
        val sealed = preferences.getString("preview:$computer", null) ?: return null
        val bytes = Base64.decode(sealed, Base64.NO_WRAP)
        require(bytes.size in 29..8192)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        }
        cipher.updateAAD(computer.toByteArray(Charsets.UTF_8))
        val clear = cipher.doFinal(bytes.copyOfRange(12, bytes.size))
        return try { clear.toString(Charsets.UTF_8) } finally { clear.fill(0) }
    }
    private fun credentials(raw: String): JSONObject {
        require(raw.toByteArray(Charsets.UTF_8).size in 1..4096)
        val value = JSONObject(raw)
        require(value.keys().asSequence().toSet() == setOf("origin", "gateway_id", "binding_id", "private_key", "desktop_public_key"))
        val origin = value.getString("origin")
        val uri = URI(origin)
        require(origin.all { it.code in 33..126 } && uri.scheme == "https" && uri.host != null &&
            uri.host == uri.host.lowercase() && uri.rawUserInfo == null && uri.rawPath.isNullOrEmpty() &&
            uri.rawQuery == null && uri.rawFragment == null && (uri.port == -1 || uri.port in 1..65535 && uri.port != 443) &&
            uri.toASCIIString() == origin)
        for (name in listOf("binding_id", "gateway_id")) require(CloudReceiptPolicy.id(value.getString(name)))
        for (name in listOf("private_key", "desktop_public_key")) {
            val key = Base64.decode(value.getString(name), Base64.NO_WRAP)
            require(key.size == 32 && key.any { it.toInt() != 0 })
            key.fill(0)
        }
        return value
    }
    private fun receiptValues(): MutableList<JSONObject> {
        val values = JSONArray(preferences.getString("receipts", "[]"))
        require(values.length() <= CloudReceiptPolicy.LIMIT)
        return (0 until values.length()).map { values.getJSONObject(it) }
            .filter { CloudReceiptPolicy.retained(it.getLong("expiresAt"), now()) }.toMutableList()
    }
    private fun saveReceipts(values: List<JSONObject>, computer: String? = null, scope: String? = null) {
        val edit = preferences.edit().putString("receipts", JSONArray(values).toString())
        if (computer != null && scope != null) edit.putString("scope:$computer", scope)
        check(edit.commit()) { "Receipt storage unavailable" }
    }
    private fun receipt(computer: String, pin: JSONObject, id: String, scope: String, event: String, expires: Long): JSONObject {
        require(CloudReceiptPolicy.id(id) && CloudReceiptPolicy.live(expires, now()) && CloudReceiptPolicy.route(scope, event, id))
        return JSONObject().put("computerId", computer).put("origin", pin.getString("origin"))
            .put("bindingId", pin.getString("binding_id")).put("gatewayId", pin.getString("gateway_id"))
            .put("notificationId", id).put("scope", scope).put("eventId", event).put("expiresAt", expires).put("acked", false)
    }
    private fun matches(receipt: JSONObject, computer: String, pin: JSONObject): Boolean =
        receipt.getString("computerId") == computer && receipt.getString("origin") == pin.getString("origin") &&
            receipt.getString("bindingId") == pin.getString("binding_id") && receipt.getString("gatewayId") == pin.getString("gateway_id")

    @Synchronized
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "state" -> result.success(state())
                "setConsent" -> {
                    val arguments = call.arguments as? Map<*, *> ?: error("Missing consent")
                    require(arguments.keys == setOf("enabled", "noticeVersion"))
                    app.cloudConsent.decide(arguments["enabled"] as Boolean, arguments["noticeVersion"] as String)
                    result.success(state())
                }
                "requestPermission" -> app.notifications.requestCloudPermission(result)
                "savePreview" -> {
                    val computer = field(call.argument<String>("computerId") ?: error("Missing computer"))
                    val raw = call.argument<String>("credentials") ?: error("Missing preview")
                    val pin = credentials(raw)
                    open(computer)?.let { require(credentials(it).toString() == pin.toString()) { "Preview identity changed" } }
                    require(preferences.all.keys.count { it.startsWith("preview:") } < 200 || preferences.contains("preview:$computer"))
                    check(preferences.edit().putString("preview:$computer", seal(computer, raw)).commit())
                    result.success(null)
                }
                "removePreview" -> {
                    val computer = field(call.argument<String>("computerId") ?: error("Missing computer"))
                    val values = receiptValues().filter { it.getString("computerId") != computer }
                    check(preferences.edit().remove("preview:$computer").remove("scope:$computer").remove("fallback:$computer")
                        .putString("receipts", JSONArray(values).toString()).commit())
                    app.notifications.clearCloudComputer(computer)
                    result.success(null)
                }
                "pendingReceipts" -> {
                    val computer = field(call.argument<String>("computerId") ?: error("Missing computer"))
                    val pin = open(computer)?.let(::credentials)
                    result.success(if (pin == null) emptyList<String>() else receiptValues()
                        .filter { matches(it, computer, pin) && !it.getBoolean("acked") && it.getLong("expiresAt") > now() }
                        .take(100).map { it.getString("notificationId") })
                }
                "markAcknowledged" -> {
                    val computer = field(call.argument<String>("computerId") ?: error("Missing computer"))
                    val pin = credentials(open(computer) ?: error("Preview is disabled"))
                    val ids = call.argument<List<String>>("ids") ?: error("Missing receipts")
                    require(ids.size <= 100 && ids.all(CloudReceiptPolicy::id))
                    val values = receiptValues()
                    values.filter { matches(it, computer, pin) && ids.contains(it.getString("notificationId")) }.forEach { it.put("acked", true) }
                    saveReceipts(values)
                    result.success(null)
                }
                "directBatch" -> {
                    check(app.cloudConsent.hasConsent() && app.notifications.cloudAllowed())
                    val computer = field(call.argument<String>("computerId") ?: error("Missing computer"))
                    val pin = credentials(open(computer) ?: error("Preview is disabled"))
                    val scope = field(call.argument<String>("scope") ?: error("Missing scope"))
                    require(CloudReceiptPolicy.validScope(scope))
                    val events = call.argument<List<Map<String, Any>>>("events") ?: error("Missing events")
                    require(events.size <= 200)
                    val baseline = preferences.getString("scope:$computer", null) != scope
                    val values = receiptValues()
                    val display = mutableListOf<Pair<JSONObject, String>>()
                    for (event in events) {
                        val id = event["notificationId"] as String
                        val eventId = event["eventId"] as String
                        val expires = (event["expiresAt"] as Number).toLong()
                        val kind = event["kind"] as String
                        require(CloudReceiptPolicy.id(id) && CloudReceiptPolicy.route(scope, eventId, id) &&
                            kind in setOf("request", "completion") && expires > 0 && expires <= now() + 3600)
                        if (expires <= now()) continue
                        val item = receipt(computer, pin, id, scope, eventId, expires)
                        if (values.any { it.getString("notificationId") == item.getString("notificationId") && it.getString("bindingId") == item.getString("bindingId") }) continue
                        require(values.size < CloudReceiptPolicy.LIMIT)
                        values.add(item)
                        if (!baseline) display.add(item to kind)
                    }
                    check(app.cloudConsent.hasConsent() && app.notifications.cloudAllowed())
                    saveReceipts(values, computer, scope) // No ACK or alert before this durable commit.
                    for ((item, kind) in display.take(10).reversed()) {
                        app.notifications.showCloudEvent(computer, scope, item.getString("eventId"),
                            if (kind == "request") "Bridge needs your input" else "Bridge task completed", "Open Bridge to view the update.")
                    }
                    result.success(null)
                }
                "takeTap" -> result.success(app.notifications.takeCloudTap()?.takeIf(::validTap))
                else -> result.notImplemented()
            }
        } catch (_: Exception) {
            app.umengPush.synchronize()
            result.error("cloud_preview_unavailable", "Private notification storage is unavailable", null)
        }
    }

    @Synchronized
    fun receive(envelope: String) {
        if (!app.cloudConsent.hasConsent() || !app.umengPush.canDeliverNotifications || !app.notifications.cloudAllowed()) return
        val revision = app.cloudConsent.revision
        try {
            require(envelope.toByteArray(Charsets.UTF_8).size <= 4096)
            val outer = JSONObject(envelope)
            require(outer.keys().asSequence().toSet() == setOf("v", "binding_id", "notification_id", "expires_at", "ciphertext"))
            if (!CloudReceiptPolicy.live(outer.getLong("expires_at"), now())) return
            val binding = outer.getString("binding_id")
            require(CloudReceiptPolicy.id(binding))
            val saved = preferences.all.keys.asSequence().filter { it.startsWith("preview:") }.take(200)
                .mapNotNull { key -> runCatching { open(key.removePrefix("preview:"))?.let { key.removePrefix("preview:") to it } }.getOrNull() }
                .firstOrNull { credentials(it.second).getString("binding_id") == binding } ?: return
            val (computer, raw) = saved
            val pin = credentials(raw)
            val clear = decrypt(raw, envelope, now())
            if (clear == null) {
                if (preferences.getLong("fallback:$computer", 0) + 60 <= now()) {
                    check(preferences.edit().putLong("fallback:$computer", now()).commit())
                    app.notifications.showCloudGeneric()
                }
                return
            }
            val value = JSONObject(clear)
            check(app.cloudConsent.hasConsent() && revision == app.cloudConsent.revision && open(computer) == raw &&
                app.umengPush.canDeliverNotifications && app.notifications.cloudAllowed())
            val item = receipt(computer, pin, value.getString("notification_id"), value.getString("scope"),
                value.getString("event_id"), value.getLong("expires_at"))
            val values = receiptValues()
            if (values.any { it.getString("notificationId") == item.getString("notificationId") && it.getString("bindingId") == binding }) return
            require(values.size < CloudReceiptPolicy.LIMIT)
            values.add(item)
            saveReceipts(values)
            if (app.cloudConsent.hasConsent() && app.umengPush.canDeliverNotifications) app.notifications.showCloudEvent(computer,
                item.getString("scope"), item.getString("eventId"), value.getString("title"), value.getString("body"))
            changed()
        } catch (_: Exception) { /* Never log keys, routes, ciphertext, or provider messages. */ }
    }

    @Synchronized fun validTap(tap: Map<String, String>): Boolean = runCatching {
        if (!app.cloudConsent.hasConsent() || !app.notifications.cloudAllowed()) return@runCatching false
        val computer = tap["computerId"] ?: return@runCatching false
        val pin = credentials(open(computer) ?: return@runCatching false)
        receiptValues().any { matches(it, computer, pin) && it.getLong("expiresAt") > now() &&
            it.getString("scope") == tap["scope"] && it.getString("eventId") == tap["eventId"] }
    }.getOrDefault(false)

    private companion object { const val KEY = "bridge.preview.v1" }
}
