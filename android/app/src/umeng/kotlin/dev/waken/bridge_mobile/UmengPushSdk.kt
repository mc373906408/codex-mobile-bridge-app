package dev.waken.bridge_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.umeng.analytics.MobclickAgent
import com.umeng.commonsdk.UMConfigure
import com.umeng.message.PushAgent
import com.umeng.message.UmengMessageHandler
import com.umeng.message.UmengNotificationClickHandler
import com.umeng.message.api.UPushRegisterCallback
import com.umeng.message.api.UPushSettingCallback
import com.umeng.message.entity.UMessage

internal class UmengPushSdk(
    private val app: BridgeApplication,
    private val permitted: () -> Boolean,
) : UmengPushBackend {
    private val main = Handler(Looper.getMainLooper())
    private val manager = app.getSystemService(NotificationManager::class.java)
    private var agent: PushAgent? = null
    private var initialized = false

    private fun trace(event: String) {
        // Only fixed local event names; never SDK errors, payloads, IDs, or tokens.
        if (BuildConfig.DEBUG && permitted()) Log.i("BridgeUPushTest", event)
    }

    init {
        if (!permitted()) stopLocalComponents()
    }

    @Suppress("DEPRECATION")
    private fun sdkComponents(): List<ComponentName> {
        val flags = PackageManager.GET_SERVICES or PackageManager.GET_RECEIVERS or
            PackageManager.GET_PROVIDERS or PackageManager.GET_ACTIVITIES or
            PackageManager.MATCH_DISABLED_COMPONENTS
        val info = app.packageManager.getPackageInfo(app.packageName, flags)
        return (info.services.orEmpty().map { it.name } + info.receivers.orEmpty().map { it.name } +
            info.providers.orEmpty().map { it.name } + info.activities.orEmpty().map { it.name })
            .filter { name -> name == ConsentGatedUmengProvider::class.java.name || SDK_PREFIXES.any { name.startsWith(it) } }
            .map { ComponentName(app, it) }
    }

    private fun components(enabled: Boolean) {
        for (component in sdkComponents()) {
            app.packageManager.setComponentEnabledSetting(component,
                if (enabled) PackageManager.COMPONENT_ENABLED_STATE_ENABLED else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP)
        }
    }

    private fun stopLocalComponents(): Boolean {
        var stopped = true
        try {
            for (notification in manager.activeNotifications) {
                if (notification.tag == TAG) manager.cancel(TAG, notification.id)
            }
        } catch (_: Exception) { stopped = false }
        try {
            val scheduler = app.getSystemService(JobScheduler::class.java)
            for (job in scheduler.allPendingJobs) {
                if (SDK_PREFIXES.any { job.service.className.startsWith(it) }) scheduler.cancel(job.id)
            }
        } catch (_: Exception) { stopped = false }
        val list = try { sdkComponents() } catch (_: Exception) { stopped = false; emptyList() }
        for (component in list) {
            try { app.stopService(Intent().setComponent(component)) } catch (_: Exception) { stopped = false }
            try {
                app.packageManager.setComponentEnabledSetting(component,
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP)
            } catch (_: Exception) { stopped = false }
        }
        return stopped
    }

    override fun register(onToken: (String) -> Unit, onFailure: () -> Unit) {
        check(permitted() && BuildConfig.UMENG_PUSH_CONFIGURED)
        trace("registration_requested")
        if (!initialized) {
            UMConfigure.setLogEnabled(false)
            // Common bundles U-App classes; disable them before common initialization.
            MobclickAgent.disable()
            MobclickAgent.setCatchUncaughtExceptions(false)
            MobclickAgent.setPageCollectionMode(MobclickAgent.PageMode.MANUAL)
            UMConfigure.enableImeiCollection(false)
            UMConfigure.enableImsiCollection(false)
            UMConfigure.enableIccidCollection(false)
            UMConfigure.enableWiFiMacCollection(false)
            UMConfigure.enableAplCollection(false)
            UMConfigure.enableInstallReferrerCollection(false)
            UMConfigure.preInit(app, BuildConfig.UMENG_PUSH_APP_KEY, BuildConfig.UMENG_PUSH_CHANNEL)
        }
        val push = PushAgent.getInstance(app)
        agent = push
        push.setDebugMode(false)
        push.setLogUploadEnable(false)
        push.setPullUpEnable(false)
        push.setPackageListenerEnable(false)
        push.setSmartEnable(false)
        push.setMessageHandler(object : UmengMessageHandler() {
            override fun handleMessage(context: Context, message: UMessage) {
                if (message.display_type != UMessage.DISPLAY_TYPE_NOTIFICATION) {
                    trace("non_notification_ignored")
                    return
                }
                trace("notification_received")
                main.post {
                    try {
                        val envelope = message.extra?.get("bridge_preview")
                        if (envelope != null) app.cloudPreview.receive(envelope)
                        else if (!BuildConfig.UMENG_PUSH_PRODUCTION) showNotification(message.msg_id)
                    } catch (_: SecurityException) {
                        trace("notification_post_security_error")
                    } catch (_: IllegalArgumentException) {
                        trace("notification_post_argument_error")
                    } catch (_: Exception) {
                        trace("notification_post_failed")
                    }
                }
            }
        })
        push.setNotificationClickHandler(object : UmengNotificationClickHandler() {
            override fun handleMessage(context: Context, message: UMessage) {
                main.post {
                    if (canDeliver()) {
                        try { app.startActivity(homeIntent().addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } catch (_: Exception) { }
                    }
                }
            }
        })
        // Install safe handlers before enabling any transport component or initializing common push hooks.
        components(true)
        if (!initialized) {
            UMConfigure.init(app, BuildConfig.UMENG_PUSH_APP_KEY, BuildConfig.UMENG_PUSH_CHANNEL,
                UMConfigure.DEVICE_TYPE_PHONE, BuildConfig.UMENG_PUSH_MESSAGE_SECRET)
            initialized = true
        }
        push.register(object : UPushRegisterCallback {
            override fun onSuccess(deviceToken: String) {
                main.post { trace("registration_token_received"); onToken(deviceToken) }
            }
            override fun onFailure(code: String, description: String) {
                main.post { trace("registration_failed"); onFailure() }
            }
        })
    }

    override fun enable(onComplete: (Boolean) -> Unit) {
        if (!permitted()) { onComplete(false); return }
        (agent ?: error("Push is not initialized")).enable(object : UPushSettingCallback {
            override fun onSuccess() { main.post { trace("push_enabled"); onComplete(true) } }
            override fun onFailure(code: String, description: String) {
                main.post { trace("push_enable_failed"); onComplete(false) }
            }
        })
    }

    override fun disable(onComplete: (Boolean) -> Unit) {
        var completed = false
        lateinit var timeout: Runnable
        fun finish(success: Boolean) {
            if (completed) return
            completed = true
            main.removeCallbacks(timeout)
            val stopped = stopLocalComponents()
            onComplete(success && stopped)
        }
        timeout = Runnable { finish(false) }
        main.postDelayed(timeout, 30_000)
        val push = agent
        if (push == null) { finish(true); return }
        try {
            push.disable(object : UPushSettingCallback {
                override fun onSuccess() { main.post { finish(true) } }
                override fun onFailure(code: String, description: String) { main.post { finish(false) } }
            })
        } catch (_: Exception) { finish(false) }
    }

    override fun onAppStart() {
        if (permitted()) agent?.onAppStart()
    }

    private fun canDeliver() = app.umengPush.canDeliverNotifications

    private fun homeIntent() = Intent(app, MainActivity::class.java).setAction(Intent.ACTION_MAIN)
        .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)

    private fun showNotification(messageId: String) {
        if (!canDeliver()) { trace("notification_blocked_session"); return }
        if (!manager.areNotificationsEnabled()) { trace("notification_blocked_permission"); return }
        manager.createNotificationChannel(NotificationChannel(CHANNEL,
            app.getString(R.string.notification_upush_channel), NotificationManager.IMPORTANCE_HIGH).apply {
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        })
        if (manager.getNotificationChannel(CHANNEL)?.importance == NotificationManager.IMPORTANCE_NONE) {
            trace("notification_blocked_channel")
            return
        }
        val pending = PendingIntent.getActivity(app, 0, homeIntent(),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        // This renderer uses local content only; vendor preprocessing is separate.
        val notification = Notification.Builder(app, CHANNEL)
            .setSmallIcon(R.drawable.umeng_push_notification_default_small_icon)
            .setContentTitle(app.getString(R.string.notification_upush_title))
            .setContentText(app.getString(R.string.notification_upush_open))
            .setContentIntent(pending)
            .setAutoCancel(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .build()
        if (canDeliver()) {
            manager.notify(TAG, messageId.hashCode(), notification)
            trace("notification_posted")
        } else trace("notification_blocked_session")
    }

    private companion object {
        const val CHANNEL = "bridge_umeng_test"
        const val TAG = "bridge_umeng_test"
        val SDK_PREFIXES = listOf("com.umeng.", "com.taobao.accs.", "org.android.agoo.")
    }
}
