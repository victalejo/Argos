package com.iaportafolio.argos.core.agent

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/*
 * Accesos tolerantes a un `JsonElement` (port de los helpers de `ArgosCore/Agent/JSONValue.swift`).
 *
 * En Android el valor JSON genérico es `kotlinx.serialization.json.JsonElement`: conserva el
 * literal numérico original (enteros y decimales no se confunden) y es inmutable. Estos
 * helpers reproducen la lectura «si es de este tipo, dámelo; si no, null» de Swift.
 */

/** El objeto subyacente si es un objeto JSON. */
val JsonElement?.objectOrNull: JsonObject? get() = this as? JsonObject

/** El array subyacente si es un array JSON. */
val JsonElement?.arrayOrNull: JsonArray? get() = this as? JsonArray

/** El texto subyacente SOLO si es una cadena JSON (un número o un bool no cuentan). */
val JsonElement?.stringOrNull: String?
    get() = (this as? JsonPrimitive)?.takeIf { it.isString }?.content

/** El booleano subyacente SOLO si es un literal `true`/`false` (la cadena "true" no cuenta). */
val JsonElement?.boolOrNull: Boolean?
    get() = (this as? JsonPrimitive)?.takeIf { !it.isString }?.content?.let {
        when (it) {
            "true" -> true
            "false" -> false
            else -> null
        }
    }

/** El número como `Double` si es un número JSON (entero o decimal). */
val JsonElement?.doubleOrNull: Double?
    get() = (this as? JsonPrimitive)?.takeIf { !it.isString && boolOrNull == null }?.content?.toDoubleOrNull()

/** Acceso por clave (`null` si no es objeto o no existe la clave), como `JSONValue[key]`. */
fun JsonElement?.field(key: String): JsonElement? = objectOrNull?.get(key)

/** Objeto JSON vacío (`{}`), el input por defecto de una herramienta. */
val EmptyJsonObject: JsonObject = JsonObject(emptyMap())
