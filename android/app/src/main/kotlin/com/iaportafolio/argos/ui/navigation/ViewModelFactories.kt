package com.iaportafolio.argos.ui.navigation

import androidx.compose.runtime.Composable
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.iaportafolio.argos.AppContainer
import com.iaportafolio.argos.ui.form.ServerFormViewModel
import com.iaportafolio.argos.ui.servers.ServersViewModel
import com.iaportafolio.argos.ui.sessions.SessionsViewModel
import com.iaportafolio.argos.terminal.RemoteTerminalSession
import com.iaportafolio.argos.ui.terminal.TerminalViewModel

/** ViewModels creados con las dependencias del [AppContainer] (DI manual, sin Hilt/Koin). */
@Composable
internal fun serversViewModel(container: AppContainer): ServersViewModel = viewModel(
    factory = viewModelFactory {
        initializer {
            ServersViewModel(container.servers, container.secrets, container.hostKeys, container.services, container.io)
        }
    },
)

@Composable
internal fun serverFormViewModel(container: AppContainer, serverId: String?): ServerFormViewModel = viewModel(
    key = "server-form:${serverId ?: "new"}",
    factory = viewModelFactory {
        initializer {
            ServerFormViewModel(serverId, container.servers, container.secrets, container.services, container.documents, container.io)
        }
    },
)

/** Con clave por servidor: en tablet el panel de detalle cambia de servidor sin cambiar de destino. */
@Composable
internal fun sessionsViewModel(container: AppContainer, serverId: String): SessionsViewModel = viewModel(
    key = "sessions:$serverId",
    factory = viewModelFactory {
        initializer { SessionsViewModel(serverId, container.servers, container.services, container.hostKeys, container.io) }
    },
)

/** Un ViewModel (y un emulador) por sesión: sobrevive a la rotación con la pantalla intacta. */
@Composable
internal fun terminalViewModel(
    container: AppContainer,
    serverId: String,
    sessionName: String,
): TerminalViewModel<RemoteTerminalSession> = viewModel(
    key = "terminal:$serverId:$sessionName",
    factory = viewModelFactory {
        initializer {
            TerminalViewModel(
                serverId = serverId,
                sessionName = sessionName,
                repository = container.servers,
                services = container.services,
                settingsStore = container.terminalSettings,
                screen = RemoteTerminalSession(),
                io = container.io,
            )
        }
    },
)
