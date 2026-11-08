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
 * Fallos del terminal en vivo ([SshjSSHService.attachTerminal]/[SshjSSHService.attachCommand])
 * una vez establecida la conexión. Separados de [SshConnectionException] para que la UI
 * distinga «no pude conectar» de «se cortó el terminal» (que se resuelve con un reattach).
 */
sealed class SshTerminalException(message: String, cause: Throwable?) : Exception(message, cause) {

    /** El servidor no abrió el canal, no concedió el PTY o no arrancó el shell. */
    class OpenFailed(val endpoint: String, cause: Throwable? = null) : SshTerminalException(
        "No se pudo abrir el terminal en $endpoint: ${cause?.message ?: "sin detalles"}. Vuelve a " +
            "intentarlo; si persiste, revisa el límite MaxSessions del servidor SSH.",
        cause,
    )

    /** La conexión se cayó con el terminal abierto (red, servidor reiniciado, keep-alive). */
    class ConnectionLost(val endpoint: String, cause: Throwable? = null) : SshTerminalException(
        "Se perdió la conexión con $endpoint mientras el terminal estaba abierto. La sesión tmux " +
            "sigue en el servidor: vuelve a conectar para retomarla.",
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
