package com.iaportafolio.argos.ui.agents

import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.agent.AgentExecStreaming
import com.iaportafolio.argos.core.userMessage
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.ClaudeTokenUnavailableException
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.terminal.TerminalServerMissingException
import kotlinx.coroutines.CancellationException

/** El servicio del servidor no implementa [AgentExecStreaming] (implementación antigua o doble). */
class AgentExecUnavailableException : Exception("Esta conexión no admite agentes persistentes.")

/** El mismo servicio del servidor visto como canal exec del agente (como `TerminalStreaming`). */
internal fun SSHServicing.agentExec(): AgentExecStreaming =
    this as? AgentExecStreaming ?: throw AgentExecUnavailableException()

/**
 * Última barrera para que el token no llegue a la UI: un stderr remoto o una herramienta del
 * agente (`env`) podrían repetirlo. Tapa el token conocido y cualquier cosa con su forma.
 */
class SecretRedactor(private val secret: String? = null) {
    fun redact(text: String): String {
        val withoutKnown = if (secret.isNullOrEmpty()) text else text.replace(secret, MASK)
        return TOKEN_PATTERN.replace(withoutKnown, MASK)
    }

    private companion object {
        const val MASK = "••••"
        val TOKEN_PATTERN = Regex("sk-ant-[A-Za-z0-9_-]{8,}")
    }
}

/** Texto de UI de un fallo de agente, sin secretos. */
internal fun Throwable.toAgentUiText(redactor: SecretRedactor): UiText = when (this) {
    is AgentExecUnavailableException -> UiText.res(R.string.agents_unsupported)
    is TerminalServerMissingException -> UiText.res(R.string.terminal_server_missing)
    is ClaudeTokenUnavailableException -> UiText.res(R.string.agents_token_unreadable)
    else -> UiText.Plain(redactor.redact(userMessage))
}

/**
 * Qué se registra de un fallo de agente: SOLO qué se hacía y el TIPO del error. Su mensaje puede
 * llevar el stderr remoto (salida de la conversación, o el token si algo lo imprimió).
 */
internal fun agentFailureLogLine(what: String, error: Throwable): String = "$what (${error::class.java.simpleName})"

/** Como `logFailures`, sin el mensaje del error (ver [agentFailureLogLine]). */
internal suspend inline fun <T> agentFailures(what: String, block: () -> T): Result<T> = try {
    Result.success(block())
} catch (cancel: CancellationException) {
    throw cancel
} catch (error: Exception) {
    ArgosLog.warn(ArgosLog.TAG_AGENT, agentFailureLogLine(what, error))
    Result.failure(error)
}
