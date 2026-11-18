package com.iaportafolio.argos.core

import com.iaportafolio.argos.core.agent.PersistentAgentScript

/**
 * A dónde lleva tocar un aviso (port de `ArgosCore/NotificationRoute.swift`, mismas claves): el
 * servidor y, si se sabe, la sesión tmux y su ventana, o un proyecto (por su carpeta), la pestaña
 * de su detalle y el agente persistente cuyo chat abrir. Viaja en los extras del `Intent`, que
 * cualquier app puede falsificar: al leerlo no se da nada por bueno. Las claves nuevas son
 * aditivas: quien las ignore abre al menos el servidor.
 */
data class NotificationRoute(
    val serverID: String,
    val session: String? = null,
    val window: Int? = null,
    /** Carpeta ABSOLUTA del proyecto (identifica el proyecto aunque se renombre). */
    val projectPath: String? = null,
    val tab: Tab? = null,
    /** Agente persistente cuyo chat abrir (implica la pestaña de agentes). */
    val agentID: String? = null,
) {
    /** Pestaña del detalle de un proyecto (los `rawValue` de Swift). */
    enum class Tab(val rawValue: String) {
        TERMINAL("terminal"), FILES("files"), CHANGES("changes"), AGENT("agent");

        companion object {
            fun of(raw: String?): Tab? = entries.firstOrNull { it.rawValue == raw }
        }
    }

    /** Pares clave → valor para los extras del `Intent` (solo lo que hay). */
    val extras: Map<String, Any>
        get() = buildMap {
            put(SERVER_KEY, serverID)
            session?.let { put(SESSION_KEY, it) }
            window?.let { put(WINDOW_KEY, it) }
            projectPath?.let { put(PROJECT_PATH_KEY, it) }
            tab?.let { put(TAB_KEY, it.rawValue) }
            agentID?.let { put(AGENT_KEY, it) }
        }

    companion object {
        const val SERVER_KEY = "argos.serverID"
        const val SESSION_KEY = "argos.session"
        const val WINDOW_KEY = "argos.window"
        const val PROJECT_PATH_KEY = "argos.projectPath"
        const val TAB_KEY = "argos.tab"
        const val AGENT_KEY = "argos.agentID"

        private const val MAX_PATH_BYTES = 4096

        /** Valida cada campo como Swift; con agente, la pestaña es siempre la de agentes. */
        fun of(
            serverID: String,
            session: String? = null,
            window: Int? = null,
            projectPath: String? = null,
            tab: Tab? = null,
            agentID: String? = null,
        ): NotificationRoute {
            val agent = agentID?.takeIf(PersistentAgentScript::isValidID)
            return NotificationRoute(
                serverID = serverID,
                session = session?.takeIf { it.isNotEmpty() },
                window = window,
                projectPath = projectPath?.let(::validPath),
                tab = if (agent != null) Tab.AGENT else tab,
                agentID = agent,
            )
        }

        /**
         * Lee los extras con [value] (devuelve `null` si falta o es de otro tipo). `null` si no
         * llevan un servidor.
         */
        fun fromExtras(value: (String) -> Any?): NotificationRoute? {
            val server = (value(SERVER_KEY) as? String)?.takeIf { it.isNotEmpty() } ?: return null
            return of(
                serverID = server,
                session = value(SESSION_KEY) as? String,
                window = value(WINDOW_KEY) as? Int,
                projectPath = value(PROJECT_PATH_KEY) as? String,
                tab = Tab.of(value(TAB_KEY) as? String),
                agentID = value(AGENT_KEY) as? String,
            )
        }

        /** Ruta absoluta, sin caracteres de control y de tamaño razonable. */
        private fun validPath(raw: String): String? = raw.takeIf {
            it.startsWith("/") && it.toByteArray(Charsets.UTF_8).size <= MAX_PATH_BYTES && it.none(Char::isISOControl)
        }
    }
}
