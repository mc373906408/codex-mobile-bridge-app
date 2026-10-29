package dev.waken.bridge_mobile

@Suppress("UNUSED_PARAMETER")
internal class UmengPushSdk(app: BridgeApplication, permitted: () -> Boolean) :
    UmengPushBackend by DisabledUmengPushBackend
