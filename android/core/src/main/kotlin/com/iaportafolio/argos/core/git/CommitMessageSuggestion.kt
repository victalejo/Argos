package com.iaportafolio.argos.core.git

import com.iaportafolio.argos.core.ShellQuoting
import com.iaportafolio.argos.core.agent.AgentExecStreaming
import com.iaportafolio.argos.core.agent.ClaudeAgentCommand
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.withTimeoutOrNull
import java.io.ByteArrayOutputStream

/**
 * «Sugerir mensaje» del panel «Cambios» (port de `ArgosCore/Git/CommitMessageSuggestion.swift`,
 * comando byte a byte): Claude Code, EN EL SERVIDOR, lee el diff de los archivos marcados y los
 * últimos mensajes del repo y propone un mensaje con el mismo estilo e idioma. Usa la suscripción
 * (token por stdin, nunca en la línea de comandos; `env -u ANTHROPIC_API_KEY` impide facturar
 * contra la API) y un modelo rápido.
 */
object CommitMessageSuggestion {

    /** Modelo de la sugerencia: rápido y barato, de sobra para un mensaje de commit. */
    const val MODEL = "haiku"

    /** Bytes máximos del prompt (un diff enorme se recorta: basta con el principio). */
    const val PROMPT_BYTE_LIMIT = 120_000

    /** Marcador del código de salida de `claude` (la salida mezcla stdout y stderr). */
    const val EXIT_MARKER = "ARGOS_CM_EXIT:"

    /** Tiempo máximo de espera de la sugerencia. */
    const val TIMEOUT_MILLIS = 120_000L

    const val CLAUDE_MISSING = "Claude Code no está instalado en el servidor."
    const val TIMED_OUT = "Claude tardó demasiado en responder."
    const val NO_RESPONSE = "Claude no respondió (la conexión se cortó)."
    const val EMPTY = "Claude no propuso ningún mensaje."

    const val INSTRUCTIONS = "Escribe el mensaje de commit para los cambios de abajo. Sigue el estilo y el idioma de " +
        "los mensajes recientes del repositorio (por ejemplo, Conventional Commits si los usan). " +
        "Primera línea de 72 caracteres como máximo. Si hace falta, deja una línea en blanco y " +
        "añade un cuerpo breve que explique el porqué. Responde SOLO con el mensaje: sin " +
        "comillas, sin bloques de código y sin comentarios."

    private fun q(value: String) = ShellQuoting.singleQuoted(value)

    /**
     * Script (sin envolver en `sh -c`: lo envuelve `runAgentExec`). La primera línea de stdin es
     * el token (vacía = credencial de `claude login` del servidor).
     */
    fun command(claudePath: String, root: String, changes: List<GitFileChange>, hasCommits: Boolean): String {
        val git = "${GitCommands.git(root)} -c core.quotepath=off"
        val diff = "$git diff --no-color --no-ext-diff"
        val tracked = changes.filter { !it.isUntracked }
        val trackedPaths = GitCommands.commitPaths(tracked).joinToString(" ") { q(it) }
        val parts = buildList {
            if (tracked.isNotEmpty()) {
                add(
                    if (hasCommits) "$diff -M HEAD -- $trackedPaths"
                    else "$diff --cached -- $trackedPaths; $diff -- $trackedPaths",
                )
            }
            changes.filter { it.isUntracked }.forEach { add("$diff --no-index -- /dev/null ${q(it.path)}") }
        }
        val diffs = parts.joinToString("\n  ") { "$it 2>/dev/null" }
        return listOf(
            "cd ${q(root)} || exit 1",
            "IFS= read -r ARGOS_OAUTH; [ -n \"\$ARGOS_OAUTH\" ] && export CLAUDE_CODE_OAUTH_TOKEN=\"\$ARGOS_OAUTH\"; unset ARGOS_OAUTH",
            "{",
            "  printf '%s\\n\\n' ${q(INSTRUCTIONS)}",
            "  echo '--- Mensajes recientes del repositorio ---'",
            "  ${GitCommands.git(root)} log -15 --format=%s 2>/dev/null",
            "  echo",
            "  echo '--- Cambios ---'",
            "  ${diffs.ifEmpty { "true" }}",
            "} | head -c $PROMPT_BYTE_LIMIT | env -u ANTHROPIC_API_KEY ${q(claudePath)} -p --model $MODEL --output-format text 2>&1",
            "rc=\$?",
            "printf '\\n%s%s\\n' '$EXIT_MARKER' \"\$rc\"",
        ).joinToString("\n")
    }

    /** Mensaje limpio a partir de la salida, o el error de `claude` (salida ≠ 0). */
    fun parse(output: String): String {
        val index = output.lastIndexOf(EXIT_MARKER)
        if (index < 0) throw GitCommandException(NO_RESPONSE)
        val code = output.substring(index + EXIT_MARKER.length).trim().toIntOrNull() ?: -1
        val text = output.substring(0, index).trim()
        if (code != 0) {
            throw GitCommandException(if (text.isEmpty()) "claude terminó con código $code." else text.takeLast(600))
        }
        val message = clean(text)
        if (message.isEmpty()) throw GitCommandException(EMPTY)
        return message
    }

    /** Quita lo que a veces añade el modelo: bloques de código, comillas o un «Mensaje:». */
    fun clean(text: String): String {
        var message = text.split("\n").filterNot { it.trim(' ', '\t').startsWith("```") }.joinToString("\n").trim()
        for (prefix in listOf("Mensaje de commit:", "Commit message:", "Mensaje:")) {
            if (message.startsWith(prefix)) message = message.removePrefix(prefix).trim()
        }
        for ((open, close) in listOf("\"" to "\"", "«" to "»", "'" to "'", "`" to "`")) {
            if (message.startsWith(open) && message.endsWith(close) && message.length > 2) {
                message = message.substring(open.length, message.length - close.length).trim()
            }
        }
        return message
    }

    /**
     * Pide la sugerencia al `claude` del servidor ([locateClaude]) y devuelve el mensaje. stdin
     * queda abierto (si se completara, `runAgentExec` dejaría de leer); termina con el EOF.
     */
    suspend fun suggest(
        locateClaude: suspend () -> String?,
        exec: AgentExecStreaming,
        root: String,
        changes: List<GitFileChange>,
        hasCommits: Boolean,
        oauthToken: String?,
    ): String {
        val claude = locateClaude() ?: throw GitCommandException(CLAUDE_MISSING)
        val command = command(claude, root, changes, hasCommits)
        val stdin = flow {
            emit(ClaudeAgentCommand.tokenLine(oauthToken))
            awaitCancellation()
        }
        val collected = ByteArrayOutputStream()
        withTimeoutOrNull(TIMEOUT_MILLIS) {
            exec.runAgentExec(command, stdin) { chunk -> collected.write(chunk) }
        } ?: throw GitCommandException(TIMED_OUT)
        return parse(collected.toByteArray().decodeToString())
    }
}
