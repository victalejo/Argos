package com.iaportafolio.argos.ui.projects

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.iaportafolio.argos.R
import com.iaportafolio.argos.ui.common.ProgressMessage
import com.iaportafolio.argos.ui.common.StatusMessage
import com.iaportafolio.argos.ui.common.asString

/**
 * Selector visual de carpetas del servidor (equivale a `RemoteDirectoryPicker` del Mac), a
 * pantalla completa: ruta actual, «subir», subcarpetas y «Usar esta carpeta».
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FolderPickerDialog(
    state: FolderPickerUiState,
    onOpenChild: (String) -> Unit,
    onGoUp: () -> Unit,
    onRetry: () -> Unit,
    onPick: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = {
                        Column {
                            Text(stringResource(R.string.folder_picker_title), maxLines = 1)
                            Text(
                                state.listing?.path ?: "…",
                                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.MiddleEllipsis,
                            )
                        }
                    },
                    navigationIcon = {
                        IconButton(onClick = onDismiss) {
                            Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.action_cancel))
                        }
                    },
                    actions = {
                        TextButton(onClick = { state.listing?.path?.let(onPick) }, enabled = state.listing != null && !state.isLoading) {
                            Text(stringResource(R.string.folder_picker_use))
                        }
                    },
                )
            },
        ) { padding ->
            Box(Modifier.fillMaxSize().padding(padding)) { FolderPickerContent(state, onOpenChild, onGoUp, onRetry) }
        }
    }
}

@Composable
private fun FolderPickerContent(state: FolderPickerUiState, onOpenChild: (String) -> Unit, onGoUp: () -> Unit, onRetry: () -> Unit) {
    val error = state.error
    val listing = state.listing
    when {
        state.isLoading -> ProgressMessage(stringResource(R.string.folder_picker_loading))
        error != null -> StatusMessage(
            icon = rememberVectorPainter(Icons.Filled.Warning),
            title = stringResource(R.string.files_failed_title),
            body = error.asString(),
        ) { Button(onClick = onRetry) { Text(stringResource(R.string.action_retry)) } }
        listing != null -> LazyColumn(Modifier.fillMaxSize()) {
            if (state.canGoUp) {
                item(key = "..") {
                    FolderRow(stringResource(R.string.folder_picker_up), onClick = onGoUp) {
                        Icon(Icons.Filled.KeyboardArrowUp, contentDescription = null)
                    }
                }
            }
            items(listing.subdirectories, key = { it }) { name ->
                FolderRow(name, onClick = { onOpenChild(name) }) {
                    Icon(painterResource(R.drawable.ic_folder), contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                }
            }
            if (listing.subdirectories.isEmpty()) {
                item(key = "empty") {
                    Surface {
                        Text(
                            stringResource(R.string.folder_picker_empty),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(16.dp),
                        )
                    }
                }
            }
        }
    }
}
