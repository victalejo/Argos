package com.iaportafolio.argos.ui.agents

import com.iaportafolio.argos.core.agent.AgentPermissionRequest
import com.iaportafolio.argos.core.agent.AgentToolSummary
import com.iaportafolio.argos.core.agent.AgentTranscriptItem
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement

/** Una fila del transcript lista para pintar. [key] es el id estable del item (clave de la lista). */
sealed interface AgentTranscriptRow {
    val key: Int

    data class User(override val key: Int, val text: String) : AgentTranscriptRow

    data class Assistant(override val key: Int, val text: String) : AgentTranscriptRow

    data class Thinking(override val key: Int, val text: String) : AgentTranscriptRow

    /** [summary] puede venir vacío; [detail] es el input completo en JSON (plegado). */
    data class Tool(override val key: Int, val name: String, val summary: String, val detail: String) : AgentTranscriptRow

    data class ToolOutput(override val key: Int, val text: String, val isError: Boolean) : AgentTranscriptRow

    data class TurnEnd(override val key: Int, val isError: Boolean, val errorText: String?, val costUsd: Double?) : AgentTranscriptRow

    data class Failure(override val key: Int, val message: String) : AgentTranscriptRow
}

/** Tarjeta de la petición de permiso pendiente: lo que el usuario debe ver antes de decidir. */
data class AgentPermissionCard(
    val requestId: String,
    val tool: String,
    /** Resumen de una línea; si la herramienta no tiene, [detail] es lo único que se muestra. */
    val summary: String,
    /** Input completo en JSON. */
    val detail: String,
)

/** Del estado del agente a lo que se pinta. Lógica pura, sin Android. */
object AgentTranscriptPresenter {
    /** Tope por bloque de texto de herramienta: un `cat` enorme no debe tumbar la lista. */
    const val MAX_BLOCK_CHARS = 20_000

    private const val TRUNCATION_MARK = "\n…"
    private val prettyJson = Json { prettyPrint = true }

    fun row(item: AgentTranscriptItem, redactor: SecretRedactor): AgentTranscriptRow = when (val kind = item.kind) {
        is AgentTranscriptItem.Kind.UserText -> AgentTranscriptRow.User(item.id, redactor.redact(kind.text))
        is AgentTranscriptItem.Kind.AssistantText -> AgentTranscriptRow.Assistant(item.id, redactor.redact(kind.text))
        is AgentTranscriptItem.Kind.Thinking -> AgentTranscriptRow.Thinking(item.id, block(kind.text, redactor))
        is AgentTranscriptItem.Kind.ToolUse -> AgentTranscriptRow.Tool(
            key = item.id,
            name = kind.name,
            summary = block(AgentToolSummary.summary(kind.name, kind.input), redactor),
            detail = block(pretty(kind.input), redactor),
        )
        is AgentTranscriptItem.Kind.ToolResult -> AgentTranscriptRow.ToolOutput(item.id, block(kind.text, redactor), kind.isError)
        is AgentTranscriptItem.Kind.Result -> AgentTranscriptRow.TurnEnd(
            key = item.id,
            isError = kind.result.isError,
            errorText = kind.result.text?.takeIf { kind.result.isError }?.let { block(it, redactor) },
            costUsd = kind.result.totalCostUSD,
        )
        is AgentTranscriptItem.Kind.Error -> AgentTranscriptRow.Failure(item.id, redactor.redact(kind.message))
    }

    /**
     * Nunca devuelve una tarjeta en blanco: sin resumen, el detalle es el contenido. El texto
     * pasa por [visibleText] para que no se pueda disfrazar lo que se va a aprobar.
     */
    fun permissionCard(request: AgentPermissionRequest, redactor: SecretRedactor): AgentPermissionCard = AgentPermissionCard(
        requestId = request.id,
        tool = visibleText(redactor.redact(request.displayName?.takeIf { it.isNotBlank() } ?: request.toolName)),
        summary = visibleText(block(AgentToolSummary.summary(request.toolName, request.input), redactor)),
        detail = visibleText(block(pretty(request.input), redactor)),
    )

    /** Sustituye controles y marcas de dirección (reordenan el texto visible), salvo `\n` y `\t`. */
    fun visibleText(text: String): String = buildString(text.length) {
        for (c in text) {
            val hidden = (c.isISOControl() && c != '\n' && c != '\t') || c in '‪'..'‮' || c in '⁦'..'⁩'
            append(if (hidden) '�' else c)
        }
    }

    private fun block(text: String, redactor: SecretRedactor): String {
        val clean = redactor.redact(text)
        return if (clean.length <= MAX_BLOCK_CHARS) clean else clean.take(MAX_BLOCK_CHARS) + TRUNCATION_MARK
    }

    private fun pretty(input: JsonElement): String = prettyJson.encodeToString(JsonElement.serializer(), input)
}

/**
 * Convierte los items en filas sin recalcular las ya hechas: el log solo crece y el reducer es
 * determinista, así que las filas de un reenganche son las mismas. No es seguro entre hilos: lo
 * usa un único colector.
 */
internal class TranscriptProjector(private val redactor: () -> SecretRedactor) {
    private var rows: List<AgentTranscriptRow> = emptyList()

    fun project(items: List<AgentTranscriptItem>): List<AgentTranscriptRow> {
        if (items.size < rows.size) rows = emptyList()
        if (items.size == rows.size) return rows
        val current = redactor()
        rows = rows + items.subList(rows.size, items.size).map { AgentTranscriptPresenter.row(it, current) }
        return rows
    }
}

/**
 * Reengancharse relee el log desde el principio. Mientras no se alcancen los bytes ya conocidos
 * se siguen pintando las filas anteriores (con sus mismas claves, así no se pierde la posición
 * de lectura) y no se muestra ninguna petición de permiso: una ya respondida reaparece un
 * instante hasta que se relee su respuesta, y se podría aprobar por error.
 */
internal class ReplayHold {
    private var held: List<AgentTranscriptRow> = emptyList()

    fun isReplaying(receivedBytes: Long, targetBytes: Long): Boolean = receivedBytes < targetBytes

    fun rowsToShow(fresh: List<AgentTranscriptRow>, replaying: Boolean): List<AgentTranscriptRow> {
        if (replaying && held.size > fresh.size) return held
        held = fresh
        return fresh
    }
}

/** ¿Está la lista pegada al final? Decide si el transcript sigue los mensajes nuevos. */
object TranscriptFollow {
    private const val BOTTOM_SLOP_PX = 48

    fun isAtBottom(lastVisibleIndex: Int?, totalItems: Int, lastVisibleEnd: Int, viewportEnd: Int): Boolean {
        if (totalItems == 0) return true
        if (lastVisibleIndex == null || lastVisibleIndex < totalItems - 1) return false
        return lastVisibleEnd <= viewportEnd + BOTTOM_SLOP_PX
    }
}
