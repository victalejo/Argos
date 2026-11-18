package com.iaportafolio.argos.core.agent

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

/**
 * Clasifica las líneas que llegan al engancharse al log de un agente persistente (port de
 * `ArgosCore/Agent/AgentAttachStreamParser.swift`, lógica pura):
 * - antes de la cabecera `argos_log_base`, lo que no es JSON es ruido del perfil del shell (un
 *   `.bashrc` que imprime algo) y NO cuenta como bytes del log;
 * - sin cabecera (servidor raro), la primera línea JSON empieza los datos;
 * - `argos_log_rotated` avisa de que el log va a sustituirse: lo que venga después en ese
 *   enganche es la copia conservada y se ignora (el cliente se reengancha). Sus bytes no cuentan.
 *
 * Tiene estado (la fase): úsalo para UN enganche.
 */
class AgentAttachStreamParser {

    sealed interface Line {
        data object Noise : Line
        data class Header(val base: Long, val from: Long) : Line
        data object Data : Line
        data object Rotated : Line
    }

    private enum class Phase { AWAITING_HEADER, DATA, ROTATED }

    private var phase = Phase.AWAITING_HEADER

    fun classify(text: String?): Line = when (phase) {
        Phase.ROTATED -> Line.Noise
        Phase.AWAITING_HEADER -> classifyBeforeHeader(text)
        Phase.DATA -> classifyData(text)
    }

    private fun classifyBeforeHeader(text: String?): Line {
        if (text == null) return Line.Noise
        PersistentAgentScript.parseLogBase(text)?.let { header ->
            phase = Phase.DATA
            return Line.Header(header.base, header.from)
        }
        if (!isJsonObject(text)) return Line.Noise
        phase = Phase.DATA
        return classifyData(text)
    }

    private fun classifyData(text: String?): Line {
        if (text == null || !isRotationMarker(text)) return Line.Data
        phase = Phase.ROTATED
        return Line.Rotated
    }

    companion object {
        /** Espera antes de reengancharse tras una rotación (que termine de sustituir el log). */
        const val ROTATION_SETTLE_DELAY_MILLIS = 500L

        fun isRotationMarker(text: String): Boolean =
            text.contains(PersistentAgentShell.ROTATED_EVENT_TYPE) &&
                AgentProtocol.decode(text) == AgentStreamEvent.Ignored(PersistentAgentShell.ROTATED_EVENT_TYPE, null)

        private fun isJsonObject(text: String): Boolean {
            val trimmed = SwiftText.trimWhitespace(text)
            if (!trimmed.startsWith("{")) return false
            return runCatching { Json.parseToJsonElement(trimmed) }.getOrNull() is JsonObject
        }
    }
}
