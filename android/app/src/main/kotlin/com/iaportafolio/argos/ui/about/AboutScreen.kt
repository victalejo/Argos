package com.iaportafolio.argos.ui.about

import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.iaportafolio.argos.BuildConfig
import com.iaportafolio.argos.R
import com.iaportafolio.argos.ui.common.ProvideConfirmedLinks

/** «Acerca de»: versión, política de privacidad, código fuente y licencias. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AboutScreen(onBack: () -> Unit, onOpenLicenses: () -> Unit) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.about_title)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back))
                    }
                },
            )
        },
    ) { padding ->
        ProvideConfirmedLinks {
            AboutContent(onOpenLicenses, Modifier.padding(padding))
        }
    }
}

@Composable
private fun AboutContent(onOpenLicenses: () -> Unit, modifier: Modifier = Modifier) {
    val uriHandler = LocalUriHandler.current
    Column(modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Image(painterResource(R.drawable.argos_icon_art), contentDescription = null, modifier = Modifier.size(96.dp))
            Text(stringResource(R.string.app_name), style = MaterialTheme.typography.headlineSmall)
            Text(
                stringResource(R.string.about_version, versionLabel(BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE)),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                stringResource(R.string.about_summary),
                style = MaterialTheme.typography.bodyMedium,
                textAlign = TextAlign.Center,
            )
        }
        HorizontalDivider()
        AboutRow(
            title = stringResource(R.string.about_privacy),
            detail = stringResource(R.string.about_privacy_detail),
            icon = { Icon(Icons.Filled.Lock, contentDescription = null) },
            onClick = { uriHandler.openUri(AboutLinks.PRIVACY_POLICY) },
        )
        AboutRow(
            title = stringResource(R.string.about_source),
            detail = stringResource(R.string.about_source_detail),
            icon = { Icon(painterResource(R.drawable.ic_code), contentDescription = null) },
            onClick = { uriHandler.openUri(AboutLinks.SOURCE_CODE) },
        )
        AboutRow(
            title = stringResource(R.string.licenses_title),
            detail = stringResource(R.string.about_licenses_detail),
            icon = { Icon(Icons.Filled.Info, contentDescription = null) },
            onClick = onOpenLicenses,
        )
    }
}

@Composable
private fun AboutRow(title: String, detail: String, icon: @Composable () -> Unit, onClick: () -> Unit) {
    ListItem(
        modifier = Modifier.clickable(role = Role.Button, onClick = onClick),
        leadingContent = icon,
        headlineContent = { Text(title) },
        supportingContent = { Text(detail) },
    )
}
