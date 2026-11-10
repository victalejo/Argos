package com.iaportafolio.argos.ui.project

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.projects.Project
import com.iaportafolio.argos.ui.common.MessageEffect
import com.iaportafolio.argos.ui.common.ProgressMessage
import com.iaportafolio.argos.ui.common.StatusMessage
import com.iaportafolio.argos.ui.common.asString

/** Ancho a partir del cual se usa el carril lateral y el explorador en dos paneles. */
val WIDE_LAYOUT_MIN_WIDTH = 840.dp

/**
 * Detalle de un proyecto (equivale a `ProjectScreen` de iOS): Terminal · Archivos · Cambios · Agentes.
 * En móvil, barra de pestañas inferior (el teclado la tapa al escribir en el terminal); en
 * pantallas anchas, carril lateral. Cada pestaña trae su propia barra superior con «atrás».
 */
@Composable
fun ProjectScreen(
    state: ProjectUiState,
    viewModel: ProjectViewModel,
    onBack: () -> Unit,
    terminal: @Composable (project: Project) -> Unit,
    files: @Composable (project: Project, twoPane: Boolean) -> Unit,
    changes: @Composable (project: Project, twoPane: Boolean) -> Unit,
    agents: @Composable (project: Project, twoPane: Boolean) -> Unit,
) {
    val snackbar = remember { SnackbarHostState() }
    MessageEffect(state.message, snackbar, viewModel::messageShown)

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val wide = maxWidth >= WIDE_LAYOUT_MIN_WIDTH
        val project = state.project
        val content = @Composable { modifier: Modifier ->
            Box(modifier) {
                if (project == null) {
                    ProjectLoadContent(state, viewModel, onBack)
                } else {
                    when (state.tab) {
                        ProjectTab.TERMINAL -> if ((state.load as? ProjectLoad.Loaded)?.isRunning == true) {
                            terminal(project)
                        } else {
                            StoppedProject(project, state.isStarting, viewModel::start, onBack)
                        }
                        ProjectTab.FILES -> files(project, wide)
                        ProjectTab.CHANGES -> changes(project, wide)
                        ProjectTab.AGENTS -> agents(project, wide)
                    }
                }
            }
        }
        if (wide) {
            Scaffold(snackbarHost = { SnackbarHost(snackbar) }, contentWindowInsets = WindowInsets(0)) { padding ->
                Row(Modifier.fillMaxSize().padding(padding)) {
                    NavigationRail {
                        ProjectTab.entries.forEach { tab ->
                            NavigationRailItem(
                                selected = state.tab == tab,
                                onClick = { viewModel.selectTab(tab) },
                                icon = { Icon(tabIcon(tab), contentDescription = null) },
                                label = { Text(stringResource(ProjectViewModel.titleOf(tab))) },
                                enabled = project != null,
                            )
                        }
                    }
                    VerticalDivider()
                    content(Modifier.weight(1f))
                }
            }
        } else {
            Scaffold(
                snackbarHost = { SnackbarHost(snackbar) },
                // Las pestañas ponen su barra superior (con su inset); aquí solo la inferior.
                contentWindowInsets = WindowInsets(0),
                bottomBar = {
                    NavigationBar {
                        ProjectTab.entries.forEach { tab ->
                            NavigationBarItem(
                                selected = state.tab == tab,
                                onClick = { viewModel.selectTab(tab) },
                                icon = { Icon(tabIcon(tab), contentDescription = null) },
                                label = { Text(stringResource(ProjectViewModel.titleOf(tab))) },
                                enabled = project != null,
                            )
                        }
                    }
                },
            ) { padding ->
                // Consumir el inset inferior evita que el terminal sume el teclado y la barra.
                content(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding))
            }
        }
    }
}

@Composable
private fun tabIcon(tab: ProjectTab): Painter = when (tab) {
    ProjectTab.TERMINAL -> painterResource(R.drawable.ic_terminal)
    ProjectTab.FILES -> painterResource(R.drawable.ic_folder)
    ProjectTab.CHANGES -> painterResource(R.drawable.ic_commit)
    ProjectTab.AGENTS -> painterResource(R.drawable.ic_sparkles)
}

/** Barra superior de las pestañas que no traen la suya. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SimpleTopBar(title: String, subtitle: String?, onBack: () -> Unit) {
    TopAppBar(
        title = {
            Column {
                Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                subtitle?.let {
                    Text(
                        it,
                        maxLines = 1,
                        overflow = TextOverflow.MiddleEllipsis,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        },
        navigationIcon = {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back))
            }
        },
    )
}

@Composable
private fun ProjectLoadContent(state: ProjectUiState, viewModel: ProjectViewModel, onBack: () -> Unit) {
    Scaffold(topBar = { SimpleTopBar(state.serverName, null, onBack) }) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when (val load = state.load) {
                ProjectLoad.Loading, is ProjectLoad.Loaded -> ProgressMessage(stringResource(R.string.project_loading))
                ProjectLoad.Missing -> StatusMessage(
                    icon = painterResource(R.drawable.ic_folder),
                    title = stringResource(R.string.project_missing_title),
                    body = stringResource(R.string.project_missing),
                )
                is ProjectLoad.Failed -> StatusMessage(
                    icon = rememberVectorPainter(Icons.Filled.Warning),
                    title = stringResource(R.string.sessions_failed_title),
                    body = load.message.asString(),
                ) { Button(onClick = viewModel::reload) { Text(stringResource(R.string.action_retry)) } }
            }
        }
    }
}

/** Terminal de un proyecto detenido: ofrece arrancarlo (equivale a `ProjectStoppedView` del Mac). */
@Composable
private fun StoppedProject(project: Project, isStarting: Boolean, onStart: () -> Unit, onBack: () -> Unit) {
    Scaffold(topBar = { SimpleTopBar(project.name, project.path, onBack) }) { padding ->
        StatusMessage(
            icon = painterResource(R.drawable.ic_terminal),
            title = stringResource(R.string.project_stopped_title),
            body = stringResource(R.string.project_stopped_body, project.path),
            modifier = Modifier.padding(padding),
        ) {
            Button(onClick = onStart, enabled = !isStarting) {
                if (isStarting) {
                    CircularProgressIndicator(Modifier.padding(end = 8.dp).size(18.dp), strokeWidth = 2.dp)
                } else {
                    Icon(Icons.Filled.PlayArrow, contentDescription = null, modifier = Modifier.padding(end = 8.dp))
                }
                Text(stringResource(R.string.project_start))
            }
        }
    }
}
