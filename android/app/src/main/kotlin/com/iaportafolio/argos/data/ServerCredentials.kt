package com.iaportafolio.argos.data

import com.iaportafolio.argos.core.AuthMethod
import com.iaportafolio.argos.core.SSHCredentials
import com.iaportafolio.argos.core.Server

/** Datos de acceso del servidor, recién leídos del almacén. Bloqueante: llamar fuera del hilo principal. */
internal fun SecretStore.credentials(server: Server): SSHCredentials = when (server.authMethod) {
    AuthMethod.PASSWORD -> SSHCredentials.Password(
        read(server.id, SecretKind.PASSWORD)
            ?: throw MissingCredentialsException(
                "No hay contraseña guardada para «${server.name}». Edita el servidor y escríbela.",
            ),
    )
    AuthMethod.KEY -> SSHCredentials.PrivateKey(
        openSSHPem = read(server.id, SecretKind.PRIVATE_KEY)
            ?: throw MissingCredentialsException(
                "No hay clave privada importada para «${server.name}». Edita el servidor e impórtala.",
            ),
        passphrase = if (server.requiresPassphrase) {
            read(server.id, SecretKind.PASSPHRASE)
                ?: throw MissingCredentialsException(
                    "Falta la passphrase de la clave de «${server.name}». Edita el servidor y escríbela.",
                )
        } else {
            null
        },
    )
}
