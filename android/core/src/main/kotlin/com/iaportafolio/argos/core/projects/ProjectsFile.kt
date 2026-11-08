package com.iaportafolio.argos.core.projects

import com.iaportafolio.argos.core.agent.SwiftJson
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Required
import kotlinx.serialization.SerializationException
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeFormatterBuilder
import java.time.format.DateTimeParseException
import java.time.temporal.ChronoUnit

/**
 * Fichero `~/.config/argos/projects.json` de un servidor (port de `ProjectsFile`), versionado
 * para poder migrarlo.
 *
 * Lo leen y escriben el Mac, el iPhone/iPad y Android, así que [encodedText] reproduce BYTE A
 * BYTE el `JSONEncoder` de Apple con `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`
 * y fechas `.iso8601`: claves ordenadas, `"clave" : valor`, sangría de 2, opcionales `nil`
 * omitidos, UUID en mayúsculas y fechas `yyyy-MM-ddTHH:mm:ssZ` en UTC.
 *
 * Al decodificar se comporta como el `JSONDecoder` de Apple: ignora claves desconocidas,
 * trata `null` como ausencia en los opcionales y EXIGE `version`, `id` y `createdAt`.
 */
@Serializable
data class ProjectsFile(
    @Required val version: Int = CURRENT_VERSION,
    val projects: List<Project>,
) {
    /** JSON tal como lo escribe Apple (sin salto de línea final). */
    fun encodedText(): String =
        SwiftJson.pretty(JSON.encodeToJsonElement(serializer(), this), escapeSlashes = false, numbers = SwiftJson.Numbers.SHORTEST)

    /** [encodedText] en UTF-8, listo para subirlo al servidor. */
    fun encoded(): ByteArray = encodedText().toByteArray(Charsets.UTF_8)

    companion object {
        const val CURRENT_VERSION = 1

        val EMPTY = ProjectsFile(projects = emptyList())

        internal val JSON: Json = Json {
            ignoreUnknownKeys = true
            explicitNulls = false
            encodeDefaults = true
        }

        /**
         * Decodifica el contenido del fichero. Vacío (o solo espacios) = sin proyectos (el
         * fichero aún no existe). Cualquier otro fallo lanza [ProjectError.InvalidFile].
         */
        fun decode(text: String): ProjectsFile {
            if (text.isBlank()) return EMPTY
            return try {
                JSON.decodeFromString(serializer(), text)
            } catch (_: SerializationException) {
                throw ProjectError.InvalidFile
            } catch (_: IllegalArgumentException) {
                throw ProjectError.InvalidFile
            }
        }
    }
}

/**
 * UUID como lo codifica Apple: `uuidString` en MAYÚSCULAS. Al decodificar exige el formato
 * canónico 8-4-4-4-12 (como `UUID(uuidString:)`) y lo normaliza a mayúsculas.
 */
internal object AppleUuidSerializer : KSerializer<String> {
    private val canonical = Regex("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")

    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("com.iaportafolio.argos.core.projects.AppleUuid", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: String) = encoder.encodeString(value.uppercase())

    override fun deserialize(decoder: Decoder): String {
        val raw = decoder.decodeString()
        if (!canonical.matches(raw)) throw SerializationException("UUID inválido: '$raw'")
        return raw.uppercase()
    }
}

/**
 * Fecha como `.iso8601` de Apple: al codificar, `2025-11-07T10:00:00Z` (UTC, fracciones de
 * segundo truncadas). Al decodificar acepta además fracciones, desfases (`+02:00`) y `z`
 * minúscula, igual que Foundation.
 */
internal object AppleIso8601InstantSerializer : KSerializer<Instant> {
    private val writer: DateTimeFormatter =
        DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC)

    private val reader: DateTimeFormatter = DateTimeFormatterBuilder()
        .parseCaseInsensitive()
        .append(DateTimeFormatter.ISO_OFFSET_DATE_TIME)
        .toFormatter()

    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("com.iaportafolio.argos.core.projects.AppleIso8601Instant", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: Instant) =
        encoder.encodeString(writer.format(value.truncatedTo(ChronoUnit.SECONDS)))

    override fun deserialize(decoder: Decoder): Instant {
        val raw = decoder.decodeString()
        return try {
            reader.parse(raw, Instant::from)
        } catch (error: DateTimeParseException) {
            throw SerializationException("Fecha ISO 8601 inválida: '$raw'", error)
        }
    }
}
