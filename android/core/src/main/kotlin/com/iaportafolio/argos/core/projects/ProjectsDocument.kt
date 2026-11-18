package com.iaportafolio.argos.core.projects

import com.iaportafolio.argos.core.agent.SwiftJson
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull

/**
 * `projects.json` tal como está en disco, para reescribirlo SIN perder nada: lo comparten el Mac,
 * el iPhone/iPad y Android, y una versión más nueva puede haber añadido campos o proyectos que
 * esta no entiende. Mismo formato en disco que [ProjectsFile] (mismos bytes si no hay nada
 * desconocido).
 *
 * - [extras]: claves desconocidas del nivel de archivo, que se conservan al reescribir.
 * - [entries]: cada proyecto, decodificado por separado. Uno inválido ([ProjectRecord.Unreadable])
 *   no invalida el resto y se reescribe tal cual, AL FINAL (como `replacingProjects` de Apple).
 *
 * Mismos bytes que `ProjectsDocument.swift` para los mismos datos: legibles en el orden de la app,
 * ilegibles detrás en su orden original, claves desconocidas conservadas (también las de
 * `macCheckout`) y la `version` del archivo.
 */
data class ProjectsDocument(
    val version: Int,
    val extras: JsonObject,
    val entries: List<ProjectRecord>,
) {
    /** Proyectos legibles, en orden. */
    val projects: List<Project> get() = entries.mapNotNull { (it as? ProjectRecord.Readable)?.project }

    /** ¿Lo escribió una versión de Argos más nueva que esta? Entonces no se puede reescribir. */
    val isNewerThanSupported: Boolean get() = version > ProjectsFile.CURRENT_VERSION

    /** Lanza [ProjectError.UnsupportedVersion] si no se puede reescribir sin perder datos. */
    fun requireWritable() {
        if (isNewerThanSupported) throw ProjectError.UnsupportedVersion(version)
    }

    /**
     * El documento con [updated] (la lista que quiere guardar la app, editada a partir de [base])
     * aplicado ENCIMA de este (lo que hay ahora en disco, que pudo cambiar desde que se leyó
     * [base]). Solo se aplica lo que la app cambió:
     *
     * - un proyecto que la app no tocó (igual que en [base]) queda como esté ahora en disco
     *   (con lo que otro dispositivo le cambiara), y si otro lo borró, sigue borrado;
     * - uno nuevo o editado se escribe con la versión de la app (conservando sus claves
     *   desconocidas en disco);
     * - uno que estaba en [base] y ya no está en [updated] se borra;
     * - lo que otro dispositivo añadió después de leer [base] se conserva (al final);
     * - los proyectos ilegibles se conservan en su posición.
     */
    fun applying(base: List<Project>, updated: List<Project>): ProjectsDocument {
        val baseById = base.associateBy { it.id }
        // Como `rawByID` de Apple: con ids repetidos manda la PRIMERA entrada.
        val currentById = entries.filterIsInstance<ProjectRecord.Readable>().reversed().associateBy { it.project.id }
        val kept = updated.mapNotNull { project ->
            val current = currentById[project.id]
            when {
                baseById[project.id] == project -> current
                else -> ProjectRecord.Readable(project, current?.raw ?: EMPTY_OBJECT)
            }
        }
        val known = updated.map { it.id }.toSet() + baseById.keys
        val addedElsewhere = entries.filterIsInstance<ProjectRecord.Readable>()
            .filter { it.project.id !in known }
            .distinctBy { it.project.id }
        val unreadable = entries.filterIsInstance<ProjectRecord.Unreadable>()
        return copy(entries = (kept + addedElsewhere).distinctBy { it.project.id } + unreadable)
    }

    /** JSON tal como lo escribe Apple (claves ordenadas, sangría de 2, sin salto final). */
    fun encodedText(): String {
        val projects = JsonArray(entries.map(ProjectRecord::toJson))
        val root = JsonObject(extras + mapOf("projects" to projects, "version" to JsonPrimitive(version)))
        return SwiftJson.pretty(root, escapeSlashes = false, numbers = SwiftJson.Numbers.SHORTEST)
    }

    /** [encodedText] en UTF-8, listo para subirlo al servidor. */
    fun encoded(): ByteArray = encodedText().toByteArray(Charsets.UTF_8)

    companion object {
        private val EMPTY_OBJECT = JsonObject(emptyMap())

        /** Claves de un proyecto que entiende esta versión (el resto se conserva tal cual). */
        internal val PROJECT_KEYS = setOf("id", "name", "group", "path", "startupCommand", "createdAt", "macCheckout")
        private val FILE_KEYS = setOf("version", "projects")

        val EMPTY = ProjectsDocument(ProjectsFile.CURRENT_VERSION, EMPTY_OBJECT, emptyList())

        /**
         * Decodifica el contenido del fichero. Vacío = sin proyectos (aún no existe). Lanza
         * [ProjectError.InvalidFile] si no es un objeto JSON con `version` entera y `projects`
         * como lista; un proyecto concreto que no se entienda NO hace fallar el resto.
         */
        fun decode(text: String): ProjectsDocument {
            if (text.isBlank()) return EMPTY
            val root = parseObject(text) ?: throw ProjectError.InvalidFile
            val version = (root["version"] as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull
                ?: throw ProjectError.InvalidFile
            val projects = root["projects"] as? JsonArray ?: throw ProjectError.InvalidFile
            return ProjectsDocument(
                version = version,
                extras = JsonObject(root - FILE_KEYS),
                entries = projects.map(::decodeEntry),
            )
        }

        private fun parseObject(text: String): JsonObject? = try {
            ProjectsFile.JSON.parseToJsonElement(text) as? JsonObject
        } catch (_: SerializationException) {
            null
        }

        private fun decodeEntry(element: JsonElement): ProjectRecord {
            val raw = element as? JsonObject ?: return ProjectRecord.Unreadable(element)
            val project = try {
                ProjectsFile.JSON.decodeFromJsonElement(Project.serializer(), raw)
            } catch (_: SerializationException) {
                null
            } catch (_: IllegalArgumentException) {
                null
            } ?: return ProjectRecord.Unreadable(element)
            return ProjectRecord.Readable(project, raw)
        }

        /** Claves conocidas de los objetos anidados (`macCheckout`). */
        private val NESTED_KEYS = mapOf("macCheckout" to setOf("macName", "macID", "date"))

        internal fun encodeProject(project: Project): JsonObject =
            ProjectsFile.JSON.encodeToJsonElement(Project.serializer(), project) as JsonObject

        /**
         * `merge` de Apple: [old] con los valores de [fresh]. Las claves conocidas mandan (ausente en
         * [fresh] = se quitó); las desconocidas de [old] se quedan, también un nivel más abajo.
         */
        internal fun merge(old: JsonObject, fresh: JsonObject): JsonObject {
            val result = (old - PROJECT_KEYS).toMutableMap()
            for ((key, value) in fresh) {
                val nested = NESTED_KEYS[key]
                val oldObject = old[key] as? JsonObject
                result[key] = if (nested != null && value is JsonObject && oldObject != null) {
                    JsonObject(oldObject - nested + value)
                } else {
                    value
                }
            }
            return JsonObject(result)
        }
    }
}

/** Un proyecto de `projects.json`. */
sealed interface ProjectRecord {
    fun toJson(): JsonElement

    /**
     * Entendido por esta versión. [raw] es su objeto en disco (vacío si es nuevo), del que se
     * conservan las claves desconocidas al reescribirlo.
     */
    data class Readable(val project: Project, val raw: JsonObject) : ProjectRecord {
        /** Claves desconocidas del proyecto. */
        val extras: JsonObject get() = JsonObject(raw - ProjectsDocument.PROJECT_KEYS)

        override fun toJson(): JsonElement = ProjectsDocument.merge(raw, ProjectsDocument.encodeProject(project))
    }

    /** No se pudo decodificar (otra versión, editado a mano…): se reescribe tal cual. */
    data class Unreadable(val raw: JsonElement) : ProjectRecord {
        override fun toJson(): JsonElement = raw
    }
}
