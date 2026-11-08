package com.iaportafolio.argos.ui.agents

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.iaportafolio.argos.R

/**
 * Petición de permiso pendiente. El contenido se desplaza dentro de la tarjeta y nunca se corta:
 * lo que se aprueba se ve entero. Los botones quedan siempre a la vista y responden a ESTA
 * petición ([AgentChatViewModel.decidePermission] comprueba su id).
 */
@Composable
internal fun AgentPermissionCardView(card: AgentPermissionCard, enabled: Boolean, showOfflineHint: Boolean, onDecide: (allow: Boolean) -> Unit) {
    // Por petición: la siguiente no hereda el detalle abierto de la anterior.
    var showDetail by rememberSaveable(card.requestId) { mutableStateOf(false) }
    Surface(color = MaterialTheme.colorScheme.tertiaryContainer, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.semantics {
                    heading()
                    liveRegion = LiveRegionMode.Assertive
                },
            ) {
                Icon(Icons.Filled.Warning, contentDescription = null, tint = MaterialTheme.colorScheme.onTertiaryContainer, modifier = Modifier.size(18.dp))
                Text(
                    stringResource(R.string.agents_permission_title, card.tool),
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onTertiaryContainer,
                )
            }
            Column(
                Modifier.fillMaxWidth().heightIn(max = 220.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                if (card.summary.isBlank()) {
                    DetailText(card.detail, monospace = true)
                } else {
                    DetailText(card.summary, monospace = true)
                    TextButton(onClick = { showDetail = !showDetail }) {
                        Text(stringResource(if (showDetail) R.string.agents_permission_detail_hide else R.string.agents_permission_detail_show))
                    }
                    if (showDetail) DetailText(card.detail, monospace = true)
                }
            }
            if (showOfflineHint) {
                Text(
                    stringResource(R.string.agents_permission_offline),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onTertiaryContainer,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                OutlinedButton(onClick = { onDecide(false) }, enabled = enabled, modifier = Modifier.weight(1f)) {
                    Text(stringResource(R.string.agents_permission_deny))
                }
                Button(onClick = { onDecide(true) }, enabled = enabled, modifier = Modifier.weight(1f)) {
                    Text(stringResource(R.string.agents_permission_allow))
                }
            }
        }
    }
}
