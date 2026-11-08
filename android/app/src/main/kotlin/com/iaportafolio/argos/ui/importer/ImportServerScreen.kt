package com.iaportafolio.argos.ui.importer

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.iaportafolio.argos.R
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.common.asString

private val CONTENT_MAX_WIDTH = 560.dp
private val SCANNER_MAX_WIDTH = 360.dp

/**
 * «Añadir desde el Mac»: escáner + enlace pegado y, al leer un código válido, la confirmación
 * (como `ImportServerSheet` de iOS). Nada se guarda hasta pulsar «Añadir servidor».
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ImportServerScreen(state: ImportServerState, actions: ImportServerActions, onClose: () -> Unit) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.import_title)) },
                navigationIcon = {
                    IconButton(onClick = onClose) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back))
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Column(
                modifier = Modifier.widthIn(max = CONTENT_MAX_WIDTH).fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                val preview = state.preview
                if (preview == null) {
                    ScanStep(state, actions)
                } else {
                    ConfirmStep(preview, state, actions)
                }
            }
        }
    }
}

@Composable
private fun ColumnScope.ScanStep(state: ImportServerState, actions: ImportServerActions) {
    Text(stringResource(R.string.import_scan_hint), style = MaterialTheme.typography.bodyMedium)
    QrScannerSection(
        onScanned = actions::onScanned,
        modifier = Modifier
            .align(Alignment.CenterHorizontally)
            .widthIn(max = SCANNER_MAX_WIDTH)
            .fillMaxWidth()
            .aspectRatio(1f)
            .clip(MaterialTheme.shapes.large),
    )
    state.inputError?.let { ErrorText(it) }
    HorizontalDivider()
    Text(
        stringResource(R.string.import_paste_title),
        style = MaterialTheme.typography.titleMedium,
        modifier = Modifier.semantics { heading() },
    )
    OutlinedTextField(
        value = state.linkText,
        onValueChange = actions::onLinkTextChange,
        label = { Text(stringResource(R.string.import_paste_label)) },
        placeholder = { Text(stringResource(R.string.import_paste_placeholder)) },
        singleLine = true,
        isError = state.inputError != null && state.linkText.isNotEmpty(),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go, autoCorrectEnabled = false),
        keyboardActions = KeyboardActions(onGo = { actions.submitLink() }),
        modifier = Modifier.fillMaxWidth(),
    )
    Button(
        onClick = actions::submitLink,
        enabled = state.linkText.isNotBlank(),
        modifier = Modifier.align(Alignment.End),
    ) { Text(stringResource(R.string.import_paste_continue)) }
}

@Composable
private fun ColumnScope.ConfirmStep(preview: ImportPreview, state: ImportServerState, actions: ImportServerActions) {
    Card {
        DetailRow(stringResource(R.string.import_field_name), preview.name)
        DetailRow(stringResource(R.string.import_field_server), preview.address, monospace = true)
        DetailRow(stringResource(R.string.import_field_access), stringResource(R.string.import_access_value))
        DetailRow(
            stringResource(R.string.import_field_identity),
            preview.hostKeyFingerprint ?: stringResource(R.string.import_identity_tofu),
            monospace = preview.hostKeyFingerprint != null,
        )
    }
    if (preview.isDuplicate) {
        Text(
            stringResource(R.string.import_duplicate),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
    if (preview.conflictsWithTrustedHostKey) {
        Card(
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.errorContainer,
                contentColor = MaterialTheme.colorScheme.onErrorContainer,
            ),
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Assertive },
        ) {
            Row(Modifier.padding(16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(Icons.Filled.Warning, contentDescription = null)
                Text(stringResource(R.string.import_conflict), style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
    state.inputError?.let { ErrorText(it) }
    state.saveError?.let { ErrorText(it) }
    Button(
        onClick = actions::confirmImport,
        enabled = state.canImport,
        modifier = Modifier.fillMaxWidth(),
    ) {
        if (state.isImporting) {
            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
        } else {
            Text(stringResource(R.string.import_add))
        }
    }
    OutlinedButton(onClick = actions::scanAgain, enabled = !state.isImporting, modifier = Modifier.fillMaxWidth()) {
        Text(stringResource(R.string.import_scan_again))
    }
    Text(
        stringResource(R.string.import_footer),
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
private fun DetailRow(label: String, value: String, monospace: Boolean = false) {
    ListItem(
        overlineContent = { Text(label) },
        headlineContent = {
            Text(
                value,
                fontFamily = if (monospace) FontFamily.Monospace else null,
                style = if (monospace) MaterialTheme.typography.bodyMedium else MaterialTheme.typography.bodyLarge,
            )
        },
    )
}

@Composable
private fun ErrorText(text: UiText) {
    Text(
        text.asString(),
        color = MaterialTheme.colorScheme.error,
        style = MaterialTheme.typography.bodyMedium,
        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
    )
}
