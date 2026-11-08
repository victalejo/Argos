package com.iaportafolio.argos.core.projects

import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.core.tmux.SessionGrouping
import kotlinx.serialization.Required
import kotlinx.serialization.Serializable
import java.time.Instant

/**
 * Un proyecto es una CARPETA del servidor con nombre propio (port de
 * `ArgosCore/Projects/Project.swift`). La sesión tmux es efímera: se crea al abrir el proyecto
 * (en su carpeta, lanzando el comando de arranque) y se puede detener sin perder el proyecto.
 *
 * Los proyectos se guardan EN EL SERVIDOR (`~/.config/argos/projects.json`, ver
 * [ProjectsFile]), así que Mac, iPhone/iPad y Android ven los mismos. Identidad con tmux: el
 * nombre de la sesión es `grupo/nombre` (o `nombre` sin grupo).
 */
@Serializable
data class Project(
    /** UUID en MAYÚSCULAS, como `UUID.uuidString` de Apple (se normaliza al decodificar). */
    @Required
    @Serializable(with = AppleUuidSerializer::class)
    val id: String = Server.newId(),
    val name: String,
    /** Grupo de la barra lateral ("ia portafolio", "tmh"…), o `null`. */
    val group: String? = null,
    /** Ruta ABSOLUTA de la carpeta en el servidor. */
    val path: String,
    /** Comando al abrir: `null` = el predeterminado de Ajustes; `""` = ninguno. */
    val startupCommand: String? = null,
    /** Apple lo escribe en ISO 8601 sin fracciones de segundo (se truncan al guardar). */
    @Required
    @Serializable(with = AppleIso8601InstantSerializer::class)
    val createdAt: Instant = Instant.now(),
    /** Si el proyecto se envió a un Mac para trabajar allí ("Enviar al Mac"). */
    val macCheckout: MacCheckout? = null,
) {
    /** Nombre de la sesión tmux que representa al proyecto mientras corre. */
    val sessionName: String
        get() = if (group.isNullOrEmpty()) name else "$group${SessionGrouping.SEPARATOR}$name"

    /** Comando de arranque efectivo (`null` = no lanzar nada). */
    fun resolvedStartupCommand(default: String): String? =
        (startupCommand ?: default).trim().ifEmpty { null }
}

/**
 * Marca de "este proyecto se está trabajando en un Mac" (port de `MacCheckout`). Vive en
 * `projects.json` del servidor, así que la ven todos los clientes.
 */
@Serializable
data class MacCheckout(
    /** Nombre del Mac (para mostrar "En el Mac de …"). */
    val macName: String,
    /** Identificador estable del Mac que lo tiene (para saber si es ESTE Mac). */
    val macID: String,
    @Serializable(with = AppleIso8601InstantSerializer::class)
    val date: Instant,
)

/**
 * Errores de proyectos (port de `ProjectError`). El `message` es el texto para la UI.
 */
sealed class ProjectError(message: String) : Exception(message, null, false, false) {
    data object InvalidFile :
        ProjectError("~/.config/argos/projects.json del servidor no es válido; no se modificó.")

    data class DuplicateName(val name: String) :
        ProjectError("Ya existe un proyecto o sesión llamado '$name' en este servidor.")

    data class MissingFolder(val path: String) :
        ProjectError("La carpeta '$path' ya no existe en el servidor. Edita el proyecto para elegir otra.")

    data object InvalidPath :
        ProjectError("La carpeta debe ser una ruta absoluta del servidor (empieza por '/').")
}
