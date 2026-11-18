package com.iaportafolio.argos.ui.terminal

import android.content.ClipboardManager
import android.content.Context
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.iaportafolio.argos.R
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.terminal.RemoteTerminalSession
import kotlinx.coroutines.delay

/** Selectores del sistema para adjuntar al terminal (sin permisos: el selector de fotos y el de archivos). */
class TerminalAttachLaunchers internal constructor(
    val openPhotos: () -> Unit,
    val openFiles: () -> Unit,
)

@Composable
fun rememberTerminalAttachLaunchers(viewModel: TerminalViewModel<RemoteTerminalSession>): TerminalAttachLaunchers {
    val photos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(MAX_PICKED)) { uris ->
        viewModel.attachUris(uris.map { it.toString() }, AttachmentKind.PHOTO)
    }
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        viewModel.attachUris(uris.map { it.toString() }, AttachmentKind.FILE)
    }
    return remember(photos, files) {
        TerminalAttachLaunchers(
            openPhotos = { photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
            openFiles = { files.launch(arrayOf("*/*")) },
        )
    }
}

/**
 * Pegar: si el portapapeles trae una imagen (captura copiada), se sube y se teclea su ruta; si no,
 * el texto de siempre. Devuelve `true` si era una imagen.
 */
fun pasteImageIfAny(context: Context, viewModel: TerminalViewModel<RemoteTerminalSession>): Boolean {
    if (!viewModel.canAttach) return false
    val clip = try {
        context.getSystemService(ClipboardManager::class.java)?.primaryClip
    } catch (error: SecurityException) {
        ArgosLog.warn(ArgosLog.TAG_TERMINAL, "Sin acceso al portapapeles (${error::class.java.simpleName})")
        null
    } ?: return false
    val description = clip.description
    val imageIndex = (0 until description.mimeTypeCount).firstOrNull { description.getMimeType(it).startsWith("image/") } ?: return false
    val uri = (0 until clip.itemCount).firstNotNullOfOrNull { clip.getItemAt(it).uri } ?: return false
    viewModel.attachPastedImage(uri.toString(), description.getMimeType(imageIndex))
    return true
}

/** Botón «Adjuntar» de la barra del terminal: foto o archivo. */
@Composable
internal fun AttachButton(launchers: TerminalAttachLaunchers) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) {
            Icon(painterResource(R.drawable.ic_attach), contentDescription = stringResource(R.string.terminal_attach))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.terminal_attach_photo)) },
                leadingIcon = { Icon(painterResource(R.drawable.ic_image), contentDescription = null) },
                onClick = { open = false; launchers.openPhotos() },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.terminal_attach_file)) },
                leadingIcon = { Icon(painterResource(R.drawable.ic_file), contentDescription = null) },
                onClick = { open = false; launchers.openFiles() },
            )
        }
    }
}

/** Aviso breve sobre el terminal (como `NoticeBanner` de iOS): «Subiendo…», «Subido» o el error. */
@Composable
internal fun NoticeBanner(notice: TerminalNotice?, onShown: (TerminalNotice) -> Unit, modifier: Modifier = Modifier) {
    notice ?: return
    LaunchedEffect(notice) {
        if (notice !is TerminalNotice.Uploading) {
            delay(if (notice is TerminalNotice.Failed) FAILED_MILLIS else DONE_MILLIS)
            onShown(notice)
        }
    }
    val text = when (notice) {
        is TerminalNotice.Uploading -> stringResource(R.string.terminal_uploading, notice.label)
        is TerminalNotice.Uploaded -> if (notice.typedPath) {
            stringResource(R.string.terminal_uploaded, notice.label)
        } else {
            stringResource(R.string.terminal_uploaded_not_typed, notice.remotePath)
        }
        is TerminalNotice.Failed -> notice.message
    }
    Row(
        modifier
            .padding(top = 8.dp, start = 16.dp, end = 16.dp)
            .background(TerminalColors.Key, RoundedCornerShape(50))
            .padding(horizontal = 14.dp, vertical = 8.dp)
            .semantics { liveRegion = LiveRegionMode.Polite },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        when (notice) {
            is TerminalNotice.Uploading -> CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = TerminalColors.OnBar)
            is TerminalNotice.Uploaded -> Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = TerminalColors.OnBar, modifier = Modifier.size(16.dp))
            is TerminalNotice.Failed -> Icon(Icons.Filled.Warning, contentDescription = null, tint = TerminalColors.OnBar, modifier = Modifier.size(16.dp))
        }
        Text(text, color = TerminalColors.OnBar, style = MaterialTheme.typography.labelLarge)
    }
}

private const val MAX_PICKED = 10
private const val DONE_MILLIS = 2_500L
private const val FAILED_MILLIS = 6_000L
