package dev.waken.bridge_mobile

import java.util.UUID

internal object CloudReceiptPolicy {
    const val LIMIT = 4096
    fun id(value: String): Boolean = runCatching { UUID.fromString(value).toString() == value }.getOrDefault(false)
    fun live(expires: Long, now: Long): Boolean = now >= 0 && expires > now && expires <= now + 3600
    fun retained(expires: Long, now: Long): Boolean = expires + 3600 > now
    fun validScope(value: String): Boolean = value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }
    fun route(scope: String, event: String, id: String): Boolean =
        validScope(scope) && event == "cloud:$id"
}
