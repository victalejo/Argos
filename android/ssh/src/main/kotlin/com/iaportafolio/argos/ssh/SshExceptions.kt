package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.agent.AgentExecCommands
import com.iaportafolio.argos.core.agent.PersistentAgentError

/**
 * Fallos al ABRIR la conexión (antes de poder ejecutar nada). En Apple los lanza Citadel con
 * sus propios tipos; aquí se traducen a mensajes accionables en español para la UI
 * (`Throwable.userMessage`). La host key distinta es [com.iaportafolio.argos.core.HostKeyMismatchException].
 */
sealed class SshConnectionException(message: String, cause: Throwable?) : Exception(message, cause) {

    /** El servidor rechazó las credenciales (contraseña o clave no autorizada). */
    class AuthenticationFailed(val username: String, cause: Throwable? = null) : SshConnectionException(
        "El servidor rechazó la autenticación de «$username». Revisa la contraseña o que la clave " +
            "esté en ~/.ssh/authorized_keys del servidor.",
        cause,
    )

    /** No se pudo abrir el socket (host desconocido, puerto cerrado, red caída). */
    class Unreachable(val endpoint: String, cause: Throwable? = null) : SshConnectionException(
        "No se pudo conectar con $endpoint. Comprueba la dirección, el puerto y la red.",
        cause,
    )

    /** El servidor no respondió a tiempo. */
    class Timeout(val endpoint: String, cause: Throwable? = null) : SshConnectionException(
        "$endpoint no respondió a tiempo. Comprueba la red o que el servidor SSH esté en marcha.",
        cause,
    )

    /** Fallo del protocolo SSH no clasificado (negociación, transporte…). */
    class ProtocolFailed(val endpoint: String, cause: Throwable? = null) : SshConnectionException(
        "Falló la conexión SSH con $endpoint: ${cause?.message ?: "sin detalles"}.",
        cause,
    )
}

/**
 * El script corto del agente persistente terminó con error (port de `AgentExecError`). El
 * mensaje incluye el final del stderr remoto, mucho más útil que un error de canal genérico.
 */
class AgentExecException(val detail: String) : Exception(AgentExecCommands.agentExecErrorMessage(detail))

/** Error del agente persistente (port de `PersistentAgentError` como excepción). */
class PersistentAgentException(val error: PersistentAgentError) : Exception(error.message)
