package com.iaportafolio.argos.core.agent

import com.iaportafolio.argos.core.SSHServicing
import java.time.Instant

/** Qué hace ahora un agente persistente (port de `PersistentAgentActivity`). */
sealed interface PersistentAgentActivity {
    val title: String

    data object Working : PersistentAgentActivity {
        override val title = "Trabajando"
    }

    data class WaitingPermission(val tool: String) : PersistentAgentActivity {
        override val title = "Espera tu permiso"
    }

    /** Vivo y esperando un mensaje (su último turno terminó). */
    data object Idle : PersistentAgentActivity {
        override val title = "Esperando"
    }

    /** En reposo (hibernado): escribirle lo reanuda. */
    data object Asleep : PersistentAgentActivity {
        override val title = "En reposo"
    }

    data object Stopped : PersistentAgentActivity {
        override val title = "Detenido"
    }
}

/**
 * Un agente persistente con lo justo para listarlo y avisar (port de
 * `ArgosCore/Agent/PersistentAgentOverview.swift`): si está vivo, en reposo o detenido, desde
 * cuándo no hace nada y qué dice el final de su log.
 */
data class PersistentAgentOverview(
    val id: String,
    val isAlive: Boolean,
    /** Bytes ABSOLUTOS del log (incluidos los rotados). */
    val logBytes: Long,
    /** Segundos desde la última escritura en el log (`null` si no se sabe). */
    val idleSeconds: Long?,
    val meta: PersistentAgentMeta,
    /** Lo que dice el final del log. */
    val attention: AgentAttention,
) {
    val info: PersistentAgentInfo get() = PersistentAgentInfo(id, isAlive, logBytes, meta)

    val activity: PersistentAgentActivity
        get() {
            if (!isAlive) return if (meta.isHibernated) PersistentAgentActivity.Asleep else PersistentAgentActivity.Stopped
            return when (val current = attention) {
                is AgentAttention.NeedsPermission -> PersistentAgentActivity.WaitingPermission(current.tool)
                is AgentAttention.Finished -> PersistentAgentActivity.Idle
                AgentAttention.None -> if (logBytes > 0) PersistentAgentActivity.Working else PersistentAgentActivity.Idle
                AgentAttention.Undetermined -> PersistentAgentActivity.Working
            }
        }

    /** Fecha aproximada de la última actividad. */
    fun lastActivity(now: Instant = Instant.now()): Instant? = idleSeconds?.let { now.minusSeconds(it) }

    companion object {
        /**
         * Una línea por agente: `id|vivo|bytes|segundos inactivo|meta en base64|final recortado en
         * base64`. Solo lectura, un viaje para todos. BYTE A BYTE el de Swift (golden `overview`).
         */
        fun command(): String {
            val log = "\"\$d/out.ndjson\""
            return "now=\$(date +%s); " +
                "for d in \"\$HOME/${PersistentAgentScript.ROOT_RELATIVE_PATH}\"/*/; do " +
                "[ -f \"\$d/meta.json\" ] || continue; " +
                "id=\$(basename \"\$d\"); p=\$(cat \"\$d/pid\" 2>/dev/null); alive=0; " +
                "[ -n \"\$p\" ] && ps -o args= -p \"\$p\" 2>/dev/null | grep -q -- \"\$id\" && alive=1; " +
                "size=\$(wc -c < $log 2>/dev/null | tr -d ' '); " +
                "${PersistentAgentScript.ABSOLUTE_SIZE}; " +
                "${PersistentAgentShell.modificationTime(log)}; idle=\$(( now - \${m:-\$now} )); " +
                "printf '%s|%s|%s|%s|' \"\$id\" \"\$alive\" \"\$size\" \"\$idle\"; " +
                "base64 < \"\$d/meta.json\" | tr -d '\\n'; printf '|'; " +
                "${PersistentAgentScript.attentionTail(log)} | base64 | tr -d '\\n'; echo; " +
                "done; true"
        }

        /** Las líneas que no se entienden se ignoran; del más reciente al más antiguo. */
        fun parse(output: String): List<PersistentAgentOverview> = SwiftText.lines(output).mapNotNull { line ->
            val fields = line.split("|", limit = 6)
            if (fields.size != 6 || !PersistentAgentScript.isValidID(fields[0])) return@mapNotNull null
            val meta = PersistentAgentScript.decodeMetaBase64(fields[4]) ?: return@mapNotNull null
            val tail = SwiftText.decodeBase64(fields[5])?.toString(Charsets.UTF_8) ?: ""
            PersistentAgentOverview(
                id = fields[0].lowercase(),
                isAlive = fields[1] == "1",
                logBytes = fields[2].toLongOrNull() ?: 0,
                idleSeconds = fields[3].toLongOrNull()?.let { maxOf(0, it) },
                meta = meta,
                attention = AgentAttention.evaluate(tail),
            )
        }.sortedByDescending { it.meta.createdAt }

        /** Agentes persistentes del servidor con su estado (un viaje SSH). */
        suspend fun load(service: SSHServicing): List<PersistentAgentOverview> =
            parse(service.runAgentScript(command()))
    }
}

/** Carpetas comparables (sin barra final; `~/x` y `$HOME/x` no se igualan aquí). */
object AgentFolderMatch {
    fun same(lhs: String, rhs: String): Boolean = normalized(lhs) == normalized(rhs)

    fun normalized(path: String): String {
        var trimmed = path.trim(' ', '\t')
        while (trimmed.length > 1 && trimmed.endsWith("/")) trimmed = trimmed.dropLast(1)
        return trimmed
    }
}
