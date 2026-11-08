package com.iaportafolio.argos.ui.agents

import com.iaportafolio.argos.core.agent.ClaudeAgentCommand
import com.iaportafolio.argos.data.AgentPermissionSelection
import com.iaportafolio.argos.ui.common.UiText
import java.time.Instant

sealed interface AgentListLoad {
    data object Loading : AgentListLoad

    data class Failed(val message: UiText) : AgentListLoad

    data object Loaded : AgentListLoad
}

/** Claude Code en este servidor (según `claude auth status`). */
sealed interface ClaudeAvailability {
    /** Aún sin comprobar, o la comprobación falló. */
    data object Unknown : ClaudeAvailability

    data object Missing : ClaudeAvailability

    data object SignedOut : ClaudeAvailability

    data class SignedIn(val subscription: String?, val email: String?) : ClaudeAvailability
}

data class AgentRow(
    val id: String,
    val title: String,
    val createdAt: Instant,
    val isAlive: Boolean,
    /** Con el que se creó: lo conserva al reanudarse, aunque cambie el ajuste. */
    val permissionMode: ClaudeAgentCommand.PermissionMode,
    /** Hay una acción en curso sobre este agente. */
    val isBusy: Boolean = false,
)

sealed interface AgentListDialog {
    /** No hay sesión de Claude: pegar un token o iniciar sesión por terminal. */
    data object AuthRequired : AgentListDialog

    /** Pegar el token, o verlo como «guardado» y borrarlo. Su valor nunca se muestra. */
    data object Token : AgentListDialog

    /** Elegir el modo de permisos de los agentes nuevos de este proyecto. */
    data object Permissions : AgentListDialog

    data class ConfirmDelete(val agentId: String, val title: String) : AgentListDialog

    /** `meta.json` pide un modo que actúa sin preguntar: reanudar exige confirmarlo. */
    data class ConfirmResume(val agentId: String, val mode: ClaudeAgentCommand.PermissionMode) : AgentListDialog
}

sealed interface AgentListEvent {
    data class OpenAgent(val agentId: String) : AgentListEvent

    /** Abrir el login guiado de `claude auth login` en una terminal. */
    data object OpenLogin : AgentListEvent
}

data class AgentListUiState(
    val projectName: String,
    val workingDirectory: String,
    val permissions: AgentPermissionSelection,
    val serverName: String = "",
    val load: AgentListLoad = AgentListLoad.Loading,
    val agents: List<AgentRow> = emptyList(),
    val isRefreshing: Boolean = false,
    val isCreating: Boolean = false,
    val claude: ClaudeAvailability = ClaudeAvailability.Unknown,
    val hasSavedToken: Boolean = false,
    val dialog: AgentListDialog? = null,
    /** Fallo al guardar el token, dentro de su diálogo. */
    val tokenError: UiText? = null,
    val message: UiText? = null,
)
