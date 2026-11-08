package com.iaportafolio.argos.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.util.UUID

/** Método de autenticación de un servidor SSH (port de `AuthMethod` en `ArgosCore/Server.swift`). */
@Serializable
enum class AuthMethod {
    /** Clave privada Ed25519 (con passphrase opcional en el almacén seguro). */
    @SerialName("key")
    KEY,

    /** Usuario + contraseña (la contraseña vive en el almacén seguro). */
    @SerialName("password")
    PASSWORD,
}

/**
 * Un servidor SSH configurable y persistible (port del modelo de `ArgosCore/Server.swift`).
 *
 * Los secretos (passphrase, contraseña) NO viven aquí: se guardan aparte, referenciados por
 * [id]. Se omite el campo Apple `privateKeyBookmark` (security-scoped bookmark del App
 * Sandbox): en Android no existe; al decodificar un `servers.json` de Apple se ignora.
 *
 * El JSON es compatible con el de Apple: mismas claves y, al faltar `authMethod`,
 * `privateKeyPath` o `requiresPassphrase`, se asumen `key`, `""` y `false`.
 */
@Serializable
data class Server(
    /** Identidad estable. Apple la codifica como UUID en MAYÚSCULAS; se conserva tal cual. */
    val id: String = newId(),
    /** Nombre visible en la UI (p. ej. "dev", "producción"). */
    val name: String,
    val host: String,
    val port: Int = DEFAULT_PORT,
    val username: String,
    val authMethod: AuthMethod = AuthMethod.KEY,
    /** Ruta legible a la clave privada (admite `~`). Solo para [AuthMethod.KEY]. */
    val privateKeyPath: String = "",
    /** Si la clave requiere passphrase (la passphrase real está en el almacén seguro). */
    val requiresPassphrase: Boolean = false,
) {
    /** Endpoint "host:port": identidad para la verificación TOFU de host key. */
    val endpoint: String get() = "$host:$port"

    companion object {
        const val DEFAULT_PORT = 22

        /** UUID nuevo con el mismo formato que `UUID().uuidString` de Apple (mayúsculas). */
        fun newId(): String = UUID.randomUUID().toString().uppercase()

        /**
         * Configuración JSON para leer/escribir `servers.json` compatible con Apple: tolera
         * claves desconocidas (`privateKeyBookmark`) y escribe también los valores por defecto.
         */
        val JSON: Json = Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
        }
    }
}
