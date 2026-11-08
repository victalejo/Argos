package com.iaportafolio.argos.core.projects

import com.iaportafolio.argos.core.SessionConnectionState

/**
 * Estado de un proyecto (o sesión suelta) a efectos del filtro de la barra lateral (port de
 * `ProjectStatus` en `ArgosCore/Projects/ProjectStatusFilter.swift`). Cada proyecto cae en
 * UNA sola categoría, en este orden de prioridad:
 * 1. En el Mac → enviado al Mac (aunque quede una sesión en el servidor).
 * 2. Abiertas → su terminal está abierto en Argos (o conectando / con error).
 * 3. Segundo plano → corre y está abierta en otro cliente.
 * 4. Dormidas → corre en el servidor pero nadie está conectado.
 * 5. Detenidas → sin sesión tmux: no consume recursos.
 */
enum class ProjectStatus {
    OPEN,
    BACKGROUND,
    DORMANT,
    STOPPED,
    ON_MAC,
    ;

    companion object {
        /**
         * @param connection estado del terminal si la sesión corre; `null` = sin sesión tmux.
         * @param onMac el proyecto está enviado al Mac.
         */
        fun of(connection: SessionConnectionState?, onMac: Boolean): ProjectStatus {
            if (onMac) return ON_MAC
            return when (connection) {
                null -> STOPPED
                SessionConnectionState.LIVE, SessionConnectionState.CONNECTING, SessionConnectionState.ERROR -> OPEN
                SessionConnectionState.ATTACHED_ELSEWHERE -> BACKGROUND
                SessionConnectionState.DORMANT -> DORMANT
            }
        }
    }
}

/**
 * Opción elegida en el filtro de la barra lateral (port de `ProjectStatusFilter`). [id] es el
 * `rawValue` de Apple, por si se persiste la elección. El orden de las constantes es el de
 * `allCases`. Se omite `systemImage` (SF Symbols, solo Apple).
 */
enum class ProjectStatusFilter(val id: String, val title: String, val help: String) {
    ALL("all", "Todos", "Todos los proyectos"),
    OPEN("open", "Abiertas", "Con el terminal abierto en Argos"),
    DORMANT("dormant", "Dormidas", "Corren en el servidor, pero nadie está conectado"),
    STOPPED("stopped", "Detenidas", "Sin sesión en el servidor: no consumen recursos"),
    ON_MAC("onMac", "En el Mac", "Enviados al Mac"),
    BACKGROUND("background", "Segundo plano", "Corren y están abiertas en otro cliente (otra terminal u otro Mac)"),
    ;

    fun includes(status: ProjectStatus): Boolean = when (this) {
        ALL -> true
        OPEN -> status == ProjectStatus.OPEN
        DORMANT -> status == ProjectStatus.DORMANT
        STOPPED -> status == ProjectStatus.STOPPED
        ON_MAC -> status == ProjectStatus.ON_MAC
        BACKGROUND -> status == ProjectStatus.BACKGROUND
    }

    companion object {
        /** Opción por su `rawValue` de Apple, o `null` si no existe. */
        fun fromId(id: String): ProjectStatusFilter? = entries.firstOrNull { it.id == id }
    }
}
