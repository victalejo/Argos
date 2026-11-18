package com.iaportafolio.argos.core.agent

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

/** `meta.json` de un agente persistente (carpeta, título, fecha, modo y reposo). */
data class PersistentAgentMeta(
    val workingDirectory: String,
    val title: String,
    val createdAt: Instant,
    /**
     * Modo con el que se creó. Reanudar lo conserva para que nunca suban los permisos sin que
     * nadie lo pida. Es texto para que un modo desconocido no invalide el `meta.json`. El archivo
     * vive en el servidor y puede editarlo el propio agente: no es de fiar para dar permisos sin
     * preguntar (ver [resumeRequiresConfirmation]).
     */
    val permissionMode: String? = null,
    /**
     * Cuándo lo hibernó el vigilante por inactividad (`null` si no). Lo escribe el servidor; al
     * reanudar se quita. Es aditivo: las versiones antiguas lo ignoran.
     */
    val hibernatedAt: Instant? = null,
) {
    /** Hibernado (parado por inactividad): escribirle lo reanuda solo. */
    val isHibernated: Boolean get() = hibernatedAt != null

    /** Los agentes sin modo guardado (o desconocido) se crearon preguntando cada permiso. */
    val resolvedPermissionMode: ClaudeAgentCommand.PermissionMode
        get() = ClaudeAgentCommand.PermissionMode.fromRawValue(permissionMode) ?: ClaudeAgentCommand.PermissionMode.DEFAULT

    /**
     * Reanudar sin preguntar permitiría a un agente limitado subirse los permisos editando su
     * `meta.json`, así que el usuario debe confirmar los modos que actúan sin pedir permiso.
     * `default` y `plan` siguen preguntando antes de cada acción.
     */
    val resumeRequiresConfirmation: Boolean
        get() = when (resolvedPermissionMode) {
            ClaudeAgentCommand.PermissionMode.BYPASS_PERMISSIONS, ClaudeAgentCommand.PermissionMode.ACCEPT_EDITS -> true
            ClaudeAgentCommand.PermissionMode.DEFAULT, ClaudeAgentCommand.PermissionMode.PLAN -> false
        }

    companion object {
        private val ISO_PATTERN = Regex("""\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})""")
        private val ISO_WRITER = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC)

        private fun iso(instant: Instant): JsonPrimitive = JsonPrimitive(ISO_WRITER.format(instant.truncatedTo(ChronoUnit.SECONDS)))

        /**
         * JSON idéntico al de `JSONEncoder.projects` de Swift (pretty, claves ordenadas, sin
         * escapar `/`, fecha ISO 8601 en UTC sin fracciones de segundo).
         */
        fun encode(meta: PersistentAgentMeta): String = SwiftJson.pretty(
            JsonObject(
                buildMap {
                    put("workingDirectory", JsonPrimitive(meta.workingDirectory))
                    put("title", JsonPrimitive(meta.title))
                    put("createdAt", iso(meta.createdAt))
                    meta.permissionMode?.let { put("permissionMode", JsonPrimitive(it)) }
                    meta.hibernatedAt?.let { put("hibernatedAt", iso(it)) }
                },
            ),
            escapeSlashes = false,
            numbers = SwiftJson.Numbers.SHORTEST,
        )

        /**
         * Decodifica como `JSONDecoder.projects`: los tres campos obligatorios; si no, `null`. Una
         * fecha `hibernatedAt` ilegible invalida el archivo, como en Swift (`decodeIfPresent`).
         */
        fun decode(json: String): PersistentAgentMeta? {
            val obj = runCatching { Json.parseToJsonElement(json) }.getOrNull().objectOrNull ?: return null
            val workingDirectory = obj["workingDirectory"].stringOrNull ?: return null
            val title = obj["title"].stringOrNull ?: return null
            val createdAt = obj["createdAt"].stringOrNull?.let(::parseDate) ?: return null
            val hibernated = obj["hibernatedAt"]
            val hibernatedAt = if (hibernated == null || hibernated is JsonNull) {
                null
            } else {
                hibernated.stringOrNull?.let(::parseDate) ?: return null
            }
            return PersistentAgentMeta(workingDirectory, title, createdAt, obj["permissionMode"].stringOrNull, hibernatedAt)
        }

        private fun parseDate(text: String): Instant? {
            if (!ISO_PATTERN.matches(text)) return null
            return runCatching { OffsetDateTime.parse(text, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant() }.getOrNull()
        }
    }
}
