package dev.waken.bridge_mobile

import android.app.Activity
import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Export an already-authorized download without copying it through a Dart byte array. */
class WorkspaceFileExport(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "dev.waken.bridge_mobile/files")
    private var pending: MethodChannel.Result? = null
    private var source: File? = null

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "save") { result.notImplemented(); return@setMethodCallHandler }
            if (pending != null) { result.error("busy", "A save dialog is already open", null); return@setMethodCallHandler }
            try {
                val file = File(call.argument<String>("path") ?: "").canonicalFile
                val root = File(activity.filesDir, "downloads").canonicalFile
                if (!file.isFile || !file.path.startsWith(root.path + File.separator) ||
                    file.parentFile?.name != "ready" || file.parentFile?.parentFile?.name?.matches(Regex("[a-f0-9]{64}")) != true) {
                    result.error("invalid_file", "Only completed workspace downloads can be exported", null)
                    return@setMethodCallHandler
                }
                val name = file.name.replace(Regex("[\\x00-\\x1f]"), "_")
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "application/octet-stream"
                    putExtra(Intent.EXTRA_TITLE, name)
                }
                pending = result
                source = file
                activity.startActivityForResult(intent, REQUEST)
            } catch (_: Exception) { pending = null; source = null; result.error("save_failed", "Could not open the system save dialog", null) }
        }
    }

    fun result(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST) return false
        val file = source
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || file == null) {
            finish(false, null)
            return true
        }
        Thread({
            var error: String? = null
            try {
                activity.contentResolver.openOutputStream(uri, "wt")?.use { output ->
                    file.inputStream().use { input -> input.copyTo(output, 64 * 1024) }
                    output.flush()
                } ?: throw IllegalStateException("No output stream")
            } catch (_: Exception) { error = "The document could not be saved completely; retry from the downloaded file" }
            activity.runOnUiThread { finish(error == null, error) }
        }, "workspace-file-export").start()
        return true
    }

    private fun finish(saved: Boolean, error: String?) {
        val result = pending ?: return
        pending = null
        source = null
        if (error == null) result.success(saved) else result.error("save_failed", error, null)
    }

    fun detach() { channel.setMethodCallHandler(null); finish(false, null) }
    companion object { private const val REQUEST = 0x6b51 }
}
