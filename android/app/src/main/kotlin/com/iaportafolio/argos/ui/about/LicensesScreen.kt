package com.iaportafolio.argos.ui.about

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import com.iaportafolio.argos.R
import com.iaportafolio.argos.ui.common.ProvideConfirmedLinks
import com.mikepenz.aboutlibraries.ui.compose.android.produceLibraries
import com.mikepenz.aboutlibraries.ui.compose.m3.LibrariesContainer
import com.mikepenz.aboutlibraries.ui.compose.style.LibraryActionBadges
import com.mikepenz.aboutlibraries.ui.compose.variant.LibraryActionKind

/**
 * «Licencias de código abierto»: la lista la genera el plugin de AboutLibraries en la build
 * (R.raw.aboutlibraries) a partir de las dependencias reales del release, con el texto completo
 * de cada licencia (offline). Los enlaces a webs y repositorios piden confirmación.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LicensesScreen(onBack: () -> Unit) {
    val libraries by produceLibraries(R.raw.aboutlibraries)
    // Id de la librería cuyo texto de licencia se muestra (sobrevive a la rotación).
    var licenseOf by rememberSaveable { mutableStateOf<String?>(null) }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.licenses_title)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back))
                    }
                },
            )
        },
    ) { padding ->
        ProvideConfirmedLinks {
            LibrariesContainer(
                libraries = libraries,
                dialogLibrary = libraries?.libraries?.firstOrNull { it.uniqueId == licenseOf },
                sheetLibrary = null,
                onDialogLibraryChange = { licenseOf = it?.uniqueId },
                onSheetLibraryChange = {},
                modifier = Modifier.fillMaxSize().padding(padding),
                actionLabels = LibraryActionBadges(
                    sponsorEnabled = false,
                    source = stringResource(R.string.licenses_source),
                    website = stringResource(R.string.licenses_website),
                    viewLicense = stringResource(R.string.licenses_view),
                ),
                // «Ver licencia» muestra el texto incluido en la app en vez de abrir la web.
                onActionClick = { library, kind ->
                    if (kind == LibraryActionKind.License) {
                        licenseOf = library.uniqueId
                        true
                    } else {
                        false
                    }
                },
                licenseDialogConfirmText = stringResource(R.string.licenses_close),
            )
        }
    }
}
