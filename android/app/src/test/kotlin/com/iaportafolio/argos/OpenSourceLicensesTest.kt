package com.iaportafolio.argos

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.Test
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * «Licencias de código abierto»: el JSON que genera el plugin de AboutLibraries (lo mismo que lee
 * la pantalla) incluye las dependencias clave con su licencia y el TEXTO de cada licencia (en modo
 * offline el plugin no lo descarga: sale de `config/licenses/`).
 *
 * Se lee con kotlinx.serialization y no con `Libs` de AboutLibraries: sus clases son bytecode de
 * Java 21 (D8 lo convierte para Android) y los tests JVM corren con el toolchain 17.
 */
class OpenSourceLicensesTest {

    private val json: JsonObject by lazy { Json.parseToJsonElement(File(GENERATED).readText()).jsonObject }
    private val libraries: List<JsonObject> by lazy { json.getValue("libraries").jsonArray.map { it.jsonObject } }
    private val licenses: JsonObject by lazy { json.getValue("licenses").jsonObject }

    private fun JsonObject.string(key: String): String? = get(key)?.jsonPrimitive?.content
    private fun JsonObject.licenseIds(): List<String> = getValue("licenses").jsonArray.map { it.jsonPrimitive.content }

    @Test
    fun `Termux figura con Apache 2_0 y sin la licencia Other de JitPack`() {
        listOf("terminal-view", "terminal-emulator").forEach { artifact ->
            val library = libraries.single { it.string("uniqueId") == "com.github.termux.termux-app:$artifact" }
            assertEquals(listOf("Apache-2.0"), library.licenseIds(), artifact)
        }
    }

    @Test
    fun `incluye las dependencias que exige la atribucion`() {
        val ids = libraries.mapNotNull { it.string("uniqueId") }.toSet()
        listOf(
            "com.hierynomus:sshj",
            "org.bouncycastle:bcprov-jdk18on",
            "com.google.zxing:core",
            "androidx.camera:camera-core",
            "com.mikepenz:multiplatform-markdown-renderer-m3",
            "androidx.work:work-runtime",
            "org.jetbrains.kotlinx:kotlinx-serialization-json",
        ).forEach { assertTrue(it in ids, "falta $it") }
    }

    @Test
    fun `cada licencia lleva su texto completo`() {
        assertTrue(licenses.isNotEmpty())
        licenses.forEach { (hash, license) ->
            val name = license.jsonObject.string("name") ?: hash
            assertTrue(!license.jsonObject.string("content").isNullOrBlank(), "sin texto: $name (añade config/licenses/*.json)")
        }
        // Toda licencia citada por una librería está definida.
        libraries.flatMap { it.licenseIds() }.forEach { assertTrue(it in licenses, "licencia sin definir: $it") }
    }

    @Test
    fun `no entran herramientas de test ni de desarrollo`() {
        val ids = libraries.mapNotNull { it.string("uniqueId") }
        listOf("org.apache.sshd", "org.junit", "app.cash.turbine", "org.jetbrains.pty4j").forEach { prefix ->
            assertTrue(ids.none { it.startsWith(prefix) }, "no debería figurar $prefix")
        }
    }

    private companion object {
        const val GENERATED = "build/generated/aboutLibraries/debug/res/raw/aboutlibraries.json"
    }
}
