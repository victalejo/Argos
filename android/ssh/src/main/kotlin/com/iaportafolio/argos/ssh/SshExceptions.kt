package com.iaportafolio.argos.ssh

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
 * Se cortó (o no se pudo abrir) el canal exec del agente ([SshjSSHService.runAgentExec]). El agente
 * corre en el servidor desacoplado de la conexión: basta con volver a engancharse.
 */
class SshAgentChannelException(val endpoint: String, cause: Throwable? = null) : Exception(
    "Se perdió la conexión con $endpoint en el canal del agente. Si ya estaba en marcha, sigue " +
        "trabajando en el servidor: vuelve a conectar para retomarlo.",
    cause,
)

/**
 * Fallos del explorador de archivos por SFTP ([SshjSSHService.listRemoteDirectory],
 * [SshjSSHService.readRemoteFile], [SshjSSHService.downloadRemoteFile]). Traducen los códigos
 * de estado SFTP a mensajes accionables en español. La ruta fuera del proyecto es
 * [com.iaportafolio.argos.core.files.FileBrowserException.OutsideProject] (contrato de `core`).
 */
sealed class RemoteFileException(val path: String, message: String, cause: Throwable?) : Exception(message, cause) {

    /** La ruta no existe en el servidor (borrada, renombrada o un enlace roto). */
    class NotFound(path: String, cause: Throwable? = null) : RemoteFileException(
        path,
        "'$path' ya no existe en el servidor. Actualiza la carpeta: puede que se haya borrado o renombrado.",
        cause,
    )

    /** El usuario remoto no tiene permiso para leer la ruta. */
    class PermissionDenied(path: String, cause: Throwable? = null) : RemoteFileException(
        path,
        "Sin permiso para leer '$path' en el servidor. Revisa sus permisos (p. ej. `chmod u+r`) o " +
            "el usuario con el que te conectas.",
        cause,
    )

    /** Fallo SFTP no clasificado (subsistema no disponible, canal cerrado, error del servidor…). */
    class SftpFailed(path: String, cause: Throwable? = null) : RemoteFileException(
        path,
        "Falló el acceso por SFTP a '$path': ${cause?.message ?: "sin detalles"}. Vuelve a intentarlo; " +
            "si persiste, comprueba que el servidor SSH tenga activado el subsistema SFTP.",
        cause,
    )

    /** La descarga llegó del servidor pero no se pudo escribir en el destino local. */
    class DestinationFailed(path: String, cause: Throwable? = null) : RemoteFileException(
        path,
        "No se pudo guardar '$path' en el dispositivo: ${cause?.message ?: "sin detalles"}. Comprueba " +
            "el espacio libre o elige otra ubicación.",
        cause,
    )
}
