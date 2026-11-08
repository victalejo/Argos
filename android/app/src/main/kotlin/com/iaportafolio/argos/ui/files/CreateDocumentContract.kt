package com.iaportafolio.argos.ui.files

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.webkit.MimeTypeMap
import androidx.activity.result.contract.ActivityResultContract
import com.iaportafolio.argos.core.files.RemotePath

/**
 * Selector del sistema «Guardar como» (`ACTION_CREATE_DOCUMENT`) con el nombre propuesto y el
 * tipo MIME deducido de la extensión de CADA archivo (el `CreateDocument` de AndroidX lo fija
 * al registrarse). Devuelve el `content://` elegido o `null` si el usuario cancela.
 */
class CreateDocumentContract : ActivityResultContract<DownloadRequest, Uri?>() {

    override fun createIntent(context: Context, input: DownloadRequest): Intent =
        Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(mimeType(input.name))
            .putExtra(Intent.EXTRA_TITLE, input.name)

    override fun parseResult(resultCode: Int, intent: Intent?): Uri? =
        intent?.takeIf { resultCode == Activity.RESULT_OK }?.data

    private fun mimeType(name: String): String =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(RemotePath.fileExtension(name)) ?: GENERIC_MIME

    private companion object {
        const val GENERIC_MIME = "application/octet-stream"
    }
}
