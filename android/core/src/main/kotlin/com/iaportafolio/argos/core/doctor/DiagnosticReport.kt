package com.iaportafolio.argos.core.doctor

import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

/** Datos de la app y del dispositivo (sin nada personal). */
data class DiagnosticAppInfo(
    val version: String,
    val build: String,
    val variant: String,
    val system: String,
    val deviceModel: String,
)

/** Una línea del registro de la app. */
data class DiagnosticLogLine(val date: Instant, val level: String, val category: String, val message: String)

/** Lo que el informe sabe del registro (sin recortar: el tope se aplica DESPUÉS de redactar). */
sealed interface DiagnosticLogExcerpt {
    data class Entries(val lines: List<DiagnosticLogLine>) : DiagnosticLogExcerpt

    data class Unavailable(val reason: String) : DiagnosticLogExcerpt
}

/** Qué parte del registro entra en el informe y con qué topes. */
data class DiagnosticLogPolicy(
    /**
     * Incluye las entradas `debug` y la categoría `agent` (texto que viene del servidor). Por
     * defecto NO: pueden llevar datos sin control.
     */
    val includesTechnicalDetail: Boolean = false,
    val maxBytes: Int = DiagnosticLogFormatter.DEFAULT_MAX_BYTES,
    val maxLineCharacters: Int = DiagnosticLogFormatter.DEFAULT_MAX_LINE_CHARACTERS,
) {
    fun admits(line: DiagnosticLogLine): Boolean =
        includesTechnicalDetail || (line.level != "debug" && line.category !in REMOTE_TEXT_CATEGORIES)

    companion object {
        /** Categorías cuyo texto puede venir del servidor sin control. */
        val REMOTE_TEXT_CATEGORIES = setOf("agent")
    }
}

/** Formato y recortes (lógica pura) del registro (port de `DiagnosticLogFormatter`). */
object DiagnosticLogFormatter {
    const val DEFAULT_MINUTES = 10
    const val DEFAULT_MAX_BYTES = 30_000
    const val DEFAULT_MAX_LINE_CHARACTERS = 600

    private val TIME: DateTimeFormatter = DateTimeFormatter.ofPattern("HH:mm:ss.SSS").withZone(ZoneOffset.UTC)

    /** `HH:mm:ss.SSS [nivel] categoría: mensaje` (hora en UTC). */
    fun format(line: DiagnosticLogLine): String {
        val flat = line.message.replace("\n", " ⏎ ")
        return "${TIME.format(line.date)} [${line.level}] ${line.category}: $flat"
    }

    /** Recorta una línea YA redactada (cortar antes podría dejar media clave a la vista). */
    fun clip(line: String, limit: Int): String =
        if (line.codePointCount(0, line.length) <= limit) line else line.take(line.offsetByCodePoints(0, limit)) + "… [recortado]"

    /** Conserva las líneas MÁS RECIENTES que quepan en [maxBytes] (en el orden recibido). */
    fun newest(lines: List<String>, maxBytes: Int): Pair<List<String>, Boolean> {
        val kept = ArrayDeque<String>()
        var used = 0
        for (line in lines.asReversed()) {
            val cost = line.toByteArray(Charsets.UTF_8).size + 1
            if (used + cost > maxBytes) return kept.toList() to true
            kept.addFirst(line)
            used += cost
        }
        return kept.toList() to false
    }
}

/** Todo lo que entra en el informe. */
data class DiagnosticInput(
    val app: DiagnosticAppInfo,
    val generatedAt: Instant,
    /** Nombre del servidor del Doctor (se redacta) y su resultado, si hay uno. */
    val serverName: String?,
    val doctor: DoctorResult?,
    val log: DiagnosticLogExcerpt,
)

/**
 * Informe de «Copiar diagnóstico» (port de `DiagnosticReport.swift`): texto plano para pegar en
 * un issue. Lo que depende del usuario (servidor, registro) pasa por [DiagnosticRedactor]; la
 * cabecera no contiene datos personales.
 */
object DiagnosticReport {

    const val REVIEW_REMINDER =
        "Revisa este texto antes de publicarlo: Argos oculta los secretos y datos personales que reconoce, " +
            "pero no puede garantizar que no se escape alguno."

    /** Motivo cuando la app no guarda registro propio (Android). */
    const val NO_APP_LOG_REASON =
        "esta versión de Android no guarda un registro propio; el informe lleva la versión, el dispositivo y el Doctor"

    /** [redactor] se comparte entre secciones para que los marcadores sean los mismos en todo el informe. */
    fun compose(input: DiagnosticInput, redactor: DiagnosticRedactor, policy: DiagnosticLogPolicy = DiagnosticLogPolicy()): String {
        val sections = mutableListOf<String>()
        sections += listOf(
            "## Argos · diagnóstico",
            "Versión: ${input.app.version} (build ${input.app.build})",
            "Variante: ${input.app.variant}",
            "Sistema: ${input.app.system}",
            "Dispositivo: ${input.app.deviceModel}",
            "Generado: ${DateTimeFormatter.ISO_INSTANT.format(input.generatedAt.truncatedTo(ChronoUnit.SECONDS))}",
            if (redactor.includesPersonalData) {
                "Datos personales: incluidos a petición del usuario (los secretos que Argos reconoce se omiten siempre)."
            } else {
                "Datos personales: ocultos (servidores, usuarios e IPs sustituidos por marcadores)."
            },
        ).joinToString("\n")
        val doctor = input.doctor
        sections += if (doctor != null) {
            val label = redactor.serverLabel(input.serverName ?: "servidor")
            "## Doctor del servidor\n" + redactor.redact(doctor.plainText(label))
        } else {
            "## Doctor del servidor\nSin servidor conectado: no se ejecutó."
        }
        sections += logSection(input.log, policy, redactor)
        sections += REVIEW_REMINDER
        // Pasada final sobre todo el informe: los secretos no dependen de ninguna sección.
        return DiagnosticSecretScrubber.scrub(sections.joinToString("\n\n")) + "\n"
    }

    private fun logSection(log: DiagnosticLogExcerpt, policy: DiagnosticLogPolicy, redactor: DiagnosticRedactor): String {
        val title = "## Registro de la app (últimos ${DiagnosticLogFormatter.DEFAULT_MINUTES} min)"
        return when (log) {
            is DiagnosticLogExcerpt.Unavailable ->
                "## Registro de la app\nNo disponible en este dispositivo: ${redactor.redact(log.reason)}. " +
                    "El resto del informe es válido."
            is DiagnosticLogExcerpt.Entries -> {
                val admitted = log.lines.filter(policy::admits)
                val omitted = log.lines.size - admitted.size
                // Orden: filtrar → redactar → recortar cada línea → recortar el total (siempre al final).
                val redacted = admitted.map {
                    DiagnosticLogFormatter.clip(redactor.redact(DiagnosticLogFormatter.format(it)), policy.maxLineCharacters)
                }
                val (kept, truncated) = DiagnosticLogFormatter.newest(redacted, policy.maxBytes)
                val notes = buildList {
                    if (truncated) add("recortado a lo más reciente")
                    if (omitted > 0) add("$omitted entradas de depuración o del agente omitidas: pueden contener texto del servidor")
                }
                val header = title + if (notes.isEmpty()) "" else " (${notes.joinToString("; ")})"
                if (kept.isEmpty()) "$header\nSin entradas." else header + "\n" + kept.joinToString("\n")
            }
        }
    }
}
