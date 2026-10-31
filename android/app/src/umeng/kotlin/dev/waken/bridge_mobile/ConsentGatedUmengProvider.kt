package dev.waken.bridge_mobile

import android.content.ContentProvider
import android.content.ContentProviderOperation
import android.content.ContentProviderResult
import android.content.ContentValues
import android.content.Context
import android.content.OperationApplicationException
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.net.Uri
import com.umeng.message.component.UmengMessageProvider

/** Provider enablement survives upgrades; cold hooks always recheck the current build's consent. */
class ConsentGatedUmengProvider : ContentProvider() {
    private var providerInfo: ProviderInfo? = null
    private var delegate: UmengMessageProvider? = null

    override fun attachInfo(context: Context, info: ProviderInfo) {
        providerInfo = ProviderInfo(info)
        super.attachInfo(context, info)
    }

    // Android invokes this before Application.onCreate; do not load any vendor code here.
    override fun onCreate() = true

    @Synchronized
    private fun active(): UmengMessageProvider? {
        val app = context?.applicationContext as? BridgeApplication ?: return null
        if (!app.hasUmengPushConsent()) return null
        return delegate ?: UmengMessageProvider().also {
            it.attachInfo(context, requireNotNull(providerInfo))
            delegate = it
        }
    }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
        selectionArgs: Array<out String>?, sortOrder: String?): Cursor? =
        active()?.query(uri, projection, selection, selectionArgs, sortOrder)

    override fun getType(uri: Uri): String? = active()?.getType(uri)

    override fun insert(uri: Uri, values: ContentValues?): Uri? = active()?.insert(uri, values)

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int =
        active()?.delete(uri, selection, selectionArgs) ?: 0

    override fun update(uri: Uri, values: ContentValues?, selection: String?,
        selectionArgs: Array<out String>?): Int = active()?.update(uri, values, selection, selectionArgs) ?: 0

    override fun applyBatch(operations: ArrayList<ContentProviderOperation>): Array<ContentProviderResult> =
        (active() ?: throw OperationApplicationException("U-Push is not enabled")).applyBatch(operations)
}
