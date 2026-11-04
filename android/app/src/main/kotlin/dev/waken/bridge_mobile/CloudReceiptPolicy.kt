package dev.waken.bridge_mobile

import java.util.UUID
import java.net.URI

internal object CloudReceiptPolicy {
    const val LIMIT = 4096
    fun origin(value: String): Boolean = runCatching {
        val uri = URI(value)
        val scheme = uri.scheme
        val host = uri.host ?: return@runCatching false
        val defaultPort = if (scheme == "https") 443 else 80
        value.length in 1..2048 && value.all { it.code in 33..126 } &&
            scheme in setOf("http", "https") && host == host.lowercase() &&
            uri.rawUserInfo == null && uri.rawPath.isNullOrEmpty() &&
            uri.rawQuery == null && uri.rawFragment == null &&
            (uri.port == -1 || uri.port in 1..65535 && uri.port != defaultPort) &&
            value == "$scheme://$host" + (if (uri.port == -1) "" else ":${uri.port}")
    }.getOrDefault(false)
    fun id(value: String): Boolean = runCatching { UUID.fromString(value).toString() == value }.getOrDefault(false)
    fun live(expires: Long, now: Long): Boolean = now >= 0 && expires > now && expires <= now + 3600
    fun retained(expires: Long, now: Long): Boolean = expires + 3600 > now
    fun validScope(value: String): Boolean = value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }
    fun route(scope: String, event: String, id: String): Boolean =
        validScope(scope) && event == "cloud:$id"
}
