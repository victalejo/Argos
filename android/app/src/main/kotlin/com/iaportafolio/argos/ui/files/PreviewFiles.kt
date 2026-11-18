package com.iaportafolio.argos.ui.files

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import com.iaportafolio.argos.core.files.PreviewTempFileName
import com.iaportafolio.argos.core.files.SpreadsheetMime
import com.iaportafolio.argos.data.ArgosLog
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * Proveedor PROPIO para entregar a otra app («Abrir con…») una copia de un archivo del servidor.
 * Subclase para no chocar en el manifiesto con el `FileProvider` de ninguna librería; solo expone
 * `cache/previews/` (ver `res/xml/preview_paths.xml`), nunca los datos de Argos.
 */
class PreviewFileProvider : FileProvider()

/**
 * Copias temporales para los visores del sistema (port de `QuickLookTempFile` de iOS): cada una en
 * una carpeta aleatoria propia dentro de `cache/previews/`, con el nombre saneado por
 * [PreviewTempFileName.safe] (el nombre viene del servidor y nunca debe salir de esa carpeta). Las de
 * más de una hora se borran al crear otra.
 */
object PreviewFiles {
    private const val DIRECTORY = "previews"
    private val MAX_AGE_MILLIS = TimeUnit.HOURS.toMillis(1)

    fun authority(context: Context): String = "${context.packageName}.previews"

    /** Escribe la copia y devuelve su `content://` del proveedor propio. */
    @Throws(IOException::class)
    fun write(context: Context, name: String, bytes: ByteArray): Uri {
        val root = File(context.cacheDir, DIRECTORY)
        cleanOld(root)
        val folder = File(root, UUID.randomUUID().toString())
        if (!folder.mkdirs()) throw IOException("No se pudo crear la carpeta temporal.")
        val file = File(folder, PreviewTempFileName.safe(name))
        // Defensa extra: el archivo debe quedar DENTRO de su carpeta.
        if (file.canonicalFile.parentFile != folder.canonicalFile) throw IOException("Nombre de archivo no válido.")
        file.writeBytes(bytes)
        return FileProvider.getUriForFile(context, authority(context), file)
    }

    /** «Abrir con…»: selector del sistema con permiso de lectura solo para esa copia. */
    fun openWith(context: Context, uri: Uri, name: String, chooserTitle: String): Boolean {
        val view = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, SpreadsheetMime.of(name))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return try {
            context.startActivity(Intent.createChooser(view, chooserTitle).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (error: ActivityNotFoundException) {
            ArgosLog.warn(ArgosLog.TAG_UI, "Ninguna app abre la hoja de cálculo", error)
            false
        }
    }

    private fun cleanOld(root: File) {
        val now = System.currentTimeMillis()
        root.listFiles()?.filter { now - it.lastModified() > MAX_AGE_MILLIS }?.forEach { old ->
            if (!old.deleteRecursively()) ArgosLog.warn(ArgosLog.TAG_STORE, "No se pudo borrar una copia temporal antigua")
        }
    }
}
