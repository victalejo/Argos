package com.iaportafolio.argos.ui.navigation

import androidx.compose.runtime.Composable
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.iaportafolio.argos.AppContainer
import com.iaportafolio.argos.ui.agents.AgentChatViewModel
import com.iaportafolio.argos.ui.agents.AgentListViewModel
import com.iaportafolio.argos.ui.agents.AgentLoginViewModel
import com.iaportafolio.argos.ui.files.RemoteFilesViewModel
import com.iaportafolio.argos.ui.form.ServerFormViewModel
import com.iaportafolio.argos.ui.project.ProjectViewModel
import com.iaportafolio.argos.ui.projects.FolderPickerViewModel
import com.iaportafolio.argos.ui.projects.ProjectsViewModel
import com.iaportafolio.argos.ui.servers.ServersViewModel
import com.iaportafolio.argos.terminal.RemoteTerminalSession
import com.iaportafolio.argos.ui.terminal.ReconnectPolicy
import com.iaportafolio.argos.ui.terminal.TerminalTarget
import com.iaportafolio.argos.ui.terminal.TerminalViewModel

/** ViewModels creados con las dependencias del [AppContainer] (DI manual, sin Hilt/Koin). */
@Composable
internal fun serversViewModel(container: AppContainer): ServersViewModel = viewModel(
    factory = viewModelFactory {
        initializer {
            ServersViewModel(container.servers, container.secrets, container.hostKeys, container.services, container.agentPermissions, container.io, container.agentNotifier, container.terminalSettings)
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
internal fun projectsViewModel(container: AppContainer, serverId: String): ProjectsViewModel = viewModel(
    key = "projects:$serverId",
    factory = viewModelFactory {
        initializer {
            ProjectsViewModel(serverId, container.servers, container.services, container.hostKeys, container.projectPreferences, container.io)
        }
    },
)

@Composable
internal fun folderPickerViewModel(container: AppContainer, serverId: String): FolderPickerViewModel = viewModel(
    key = "folder-picker:$serverId",
    factory = viewModelFactory {
        initializer { FolderPickerViewModel(serverId, container.servers, container.services, container.io) }
    },
)

@Composable
internal fun projectViewModel(container: AppContainer, serverId: String, projectId: String): ProjectViewModel = viewModel(
    key = "project:$serverId:$projectId",
    factory = viewModelFactory {
        initializer {
            ProjectViewModel(serverId, projectId, container.servers, container.services, container.projectPreferences, container.io)
        }
    },
)

/** Uno por carpeta raíz: si el proyecto cambia de carpeta, el explorador empieza de cero. */
@Composable
internal fun filesViewModel(container: AppContainer, serverId: String, root: String): RemoteFilesViewModel = viewModel(
    key = "files:$serverId:$root",
    factory = viewModelFactory {
        initializer {
            RemoteFilesViewModel(serverId, root, container.servers, container.services, container.documentWriter, container.io)
        }
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
                keepAlive = container.activeTerminals,
            )
        }
    },
)

/** Uno por carpeta: si el proyecto cambia de carpeta, sus agentes son otros. */
@Composable
internal fun agentListViewModel(
    container: AppContainer,
    serverId: String,
    projectName: String,
    workingDirectory: String,
): AgentListViewModel = viewModel(
    key = "agents:$serverId:$workingDirectory",
    factory = viewModelFactory {
        initializer {
            AgentListViewModel(
                serverId,
                projectName,
                workingDirectory,
                container.servers,
                container.services,
                container.claudeTokens,
                container.agentPermissions,
                container.io,
            )
        }
    },
)

@Composable
internal fun agentChatViewModel(container: AppContainer, serverId: String, agentId: String): AgentChatViewModel = viewModel(
    key = "agent-chat:$serverId:$agentId",
    factory = viewModelFactory {
        initializer {
            AgentChatViewModel(
                serverId,
                agentId,
                container.servers,
                container.services,
                container.claudeTokens,
                container.io,
                attention = container.agentNotifier,
            )
        }
    },
)

@Composable
internal fun agentLoginViewModel(container: AppContainer, serverId: String): AgentLoginViewModel = viewModel(
    key = "agent-login:$serverId",
    factory = viewModelFactory {
        initializer { AgentLoginViewModel(serverId, container.servers, container.services) }
    },
)

/**
 * El PTY de `claude auth login`. Sin reintentos automáticos: relanzar el comando invalidaría el
 * enlace que el usuario tiene abierto en el navegador.
 */
@Composable
internal fun agentLoginTerminalViewModel(
    container: AppContainer,
    serverId: String,
    login: AgentLoginViewModel,
): TerminalViewModel<RemoteTerminalSession> = viewModel(
    key = "agent-login-terminal:$serverId",
    factory = viewModelFactory {
        initializer {
            TerminalViewModel(
                serverId = serverId,
                sessionName = "claude auth login",
                repository = container.servers,
                services = container.services,
                settingsStore = container.terminalSettings,
                screen = RemoteTerminalSession(),
                io = container.io,
                policy = ReconnectPolicy(maxAttempts = 0),
                target = TerminalTarget.Command(login::loginCommand),
                outputTap = login::onTerminalOutput,
            )
        }
    },
)
