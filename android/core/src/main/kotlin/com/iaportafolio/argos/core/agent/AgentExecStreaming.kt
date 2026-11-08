package com.iaportafolio.argos.core.agent

import kotlinx.coroutines.flow.Flow

/**
 * Canal exec bidireccional sin PTY (8-bit safe) para el agente: lanzarlo y engancharse a su
 * log (port de `runAgentExec`/`claudeAuthStatus` de `SSHServicing.swift`). Separado de
 * `SSHServicing` igual que `TerminalStreaming`.
 */
interface AgentExecStreaming {

    /**
     * Ejecuta [command] y suspende mientras viva: los bytes de [stdin] van al stdin remoto y
     * el STDOUT se entrega a [output] en orden (el stderr se guarda solo para el error).
     *
     * Como en Apple, termina en cuanto acaba una de las dos ramas: EOF del proceso, o que
     * [stdin] se complete (por eso un enganche pasa un flujo que nunca termina). Cancelar
     * cierra el canal sin matar nada que siga corriendo en el servidor por su cuenta. Si falla
     * y hubo stderr, lanza [AgentExecException] con su final.
     */
    suspend fun runAgentExec(command: String, stdin: Flow<ByteArray>, output: suspend (ByteArray) -> Unit)

    /** `claude auth status --json`; `null` si `claude` no está instalado en el servidor. */
    suspend fun claudeAuthStatus(): ClaudeAuthStatus?
}

/** Un script o canal del agente falló (port de `AgentExecError`); lleva el final del stderr remoto. */
class AgentExecException(val detail: String) : Exception(AgentExecCommands.agentExecErrorMessage(detail))

/** Error del agente persistente (port de `PersistentAgentError` como excepción). */
class PersistentAgentException(val error: PersistentAgentError) : Exception(error.message)
