package dev.waken.bridge_mobile

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

class NotificationListenerService : Service() {
    private val bridge get() = (application as BridgeApplication).notifications

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(BridgeNotifications.LISTENER_ID, bridge.ongoingNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING)
        } else startForeground(BridgeNotifications.LISTENER_ID, bridge.ongoingNotification())
        bridge.serviceState(true)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!bridge.canListen()) stopSelf()
        // No boot/force-stop resurrection. Reopening the app automatically restores listening.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        bridge.serviceState(false)
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
