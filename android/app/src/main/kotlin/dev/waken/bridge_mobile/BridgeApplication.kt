package dev.waken.bridge_mobile

import android.app.Application
import android.content.Context

class BridgeApplication : Application() {
    private external fun initializeTls(context: Context)

    override fun onCreate() {
        super.onCreate()
        System.loadLibrary("bridge_native")
        initializeTls(applicationContext)
    }
}
