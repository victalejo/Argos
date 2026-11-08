package com.iaportafolio.argos.core

/**
 * Errores tipados del servicio SSH (port de `SSHService.SSHServiceError`). El `message` es
 * el texto accionable que se muestra en la UI (ver [userMessage]).
 */
sealed class SSHServiceError(message: String, cause: Throwable? = null) : Exception(message, cause) {

    /**
     * No se pudo leer la clave privada. Apple añade una pista sobre el permiso de `~/.ssh`
     * del sandbox (`SSHDirectoryAccess`); en Android no aplica y se omite.
     */
    class KeyUnreadable(val path: String, cause: Throwable? = null) :
        SSHServiceError("No se pudo leer la clave privada en $path.", cause)

    class KeyParseFailed(cause: Throwable? = null) : SSHServiceError(
        "No se pudo cargar la clave Ed25519. Verifica que esté en formato OpenSSH " +
            "y, si tiene passphrase, que se haya inyectado correctamente.",
        cause,
    )

    class CommandFailed(val exitCode: Int, val detail: String) :
        SSHServiceError("El comando remoto falló (código $exitCode): $detail")

    class TmuxNotInstalled : SSHServiceError("tmux no está instalado en el servidor.")

    class InstallFailed(val detail: String) : SSHServiceError("No se pudo instalar tmux. $detail")

    class ConfigFailed(val detail: String) : SSHServiceError("No se pudo crear ~/.tmux.conf. $detail")

    class UploadFailed(val detail: String) : SSHServiceError("No se pudo subir el archivo al servidor. $detail")
}
