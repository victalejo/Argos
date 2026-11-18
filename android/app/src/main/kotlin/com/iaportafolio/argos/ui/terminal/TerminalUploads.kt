package com.iaportafolio.argos.ui.terminal

import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.TerminalAttachment
import com.iaportafolio.argos.core.userMessage
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.AttachmentSource
import com.iaportafolio.argos.data.PickedAttachment
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext
import java.time.Instant

/** Cómo llegó el adjunto: decide el nombre en el servidor. */
enum class AttachmentKind {
    /** Archivo con nombre (selector de archivos o «Compartir»): `uploadDroppedFile`. */
    FILE,

    /** Foto del selector del sistema: `foto-AAAAMMDD-HHMMSS.ext` si no trae nombre. */
    PHOTO,

    /** Imagen pegada del portapapeles: `uploadPastedFile` con su extensión. */
    PASTED_IMAGE,
}

/**
 * Sube lo adjuntado al terminal y teclea su ruta (port de `TouchTerminalController.attach` y
 * `TerminalInputActions` de iOS). Lee con tope ([TerminalAttachment.MAX_BYTES]): un archivo enorme
 * no se carga entero. Nunca lanza: cada paso queda en un [TerminalNotice].
 */
class TerminalUploads(
    private val source: AttachmentSource,
    private val io: CoroutineDispatcher,
    private val clock: () -> Instant = Instant::now,
) {
    /** Devuelve el aviso final; [type] escribe la ruta en el PTY (`false` si no hay attach abierto). */
    suspend fun upload(
        service: SSHServicing,
        attachment: PickedAttachment,
        kind: AttachmentKind,
        notify: (TerminalNotice) -> Unit,
        type: (String) -> Boolean,
    ): TerminalNotice {
        val label = label(attachment, kind)
        val size = attachment.size
        if (size != null && size > TerminalAttachment.MAX_BYTES) return failed(TerminalAttachment.tooLargeMessage(label), notify)
        notify(TerminalNotice.Uploading(label))
        return try {
            val data = withContext(io) { source.read(attachment.uri, TerminalAttachment.MAX_BYTES) }
            if (data.size > TerminalAttachment.MAX_BYTES) return failed(TerminalAttachment.tooLargeMessage(label), notify)
            val remotePath = withContext(io) {
                when (kind) {
                    AttachmentKind.PASTED_IMAGE -> service.uploadPastedFile(data, TerminalAttachment.imageExtension(attachment.mimeType))
                    AttachmentKind.FILE, AttachmentKind.PHOTO -> service.uploadDroppedFile(data, label)
                }
            }
            val typed = type(TerminalAttachment.typedPath(remotePath))
            TerminalNotice.Uploaded(label, remotePath, typed).also(notify)
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (error: Exception) {
            ArgosLog.warn(ArgosLog.TAG_TERMINAL, "No se pudo subir un adjunto al terminal", error)
            failed("No se pudo subir «$label»: ${error.userMessage}", notify)
        }
    }

    private fun failed(message: String, notify: (TerminalNotice) -> Unit): TerminalNotice =
        TerminalNotice.Failed(message).also(notify)

    /** Nombre con el que se sube y se muestra. */
    fun label(attachment: PickedAttachment, kind: AttachmentKind): String {
        val name = attachment.displayName
        return when {
            kind == AttachmentKind.PASTED_IMAGE -> "imagen.${TerminalAttachment.imageExtension(attachment.mimeType)}"
            name != null -> name
            kind == AttachmentKind.PHOTO || attachment.mimeType?.startsWith("image/") == true ->
                TerminalAttachment.photoFileName(extensionOf(attachment.mimeType), clock())
            else -> "archivo"
        }
    }

    private fun extensionOf(mimeType: String?): String? = mimeType?.takeIf { it.startsWith("image/") }?.let(TerminalAttachment::imageExtension)
}
