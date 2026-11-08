package com.iaportafolio.argos

import org.junit.jupiter.api.Test
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Ficha de Google Play (Gradle Play Publisher, `src/main/play/`): límites de Play Console para que
 * `publishListing` no falle a mitad de subida. Los tests JVM corren con el módulo `app` como
 * directorio de trabajo.
 */
class PlayListingTest {

    private val play = File("src/main/play")

    @ParameterizedTest
    @ValueSource(strings = ["es-419", "es-ES", "en-US"])
    fun `la ficha de cada idioma respeta los limites de Play`(language: String) {
        val dir = File(play, "listings/$language")
        LIMITS.forEach { (file, limit) ->
            val text = File(dir, file).readText()
            assertTrue(text.isNotBlank(), "$language/$file vacío")
            assertEquals(text.trim(), text, "$language/$file: sin espacios ni saltos al principio o al final")
            val length = text.codePointCount(0, text.length)
            assertTrue(length <= limit, "$language/$file: $length caracteres (máximo $limit)")
        }
    }

    @Test
    fun `el idioma por defecto es es-419 y tiene notas de la prueba interna`() {
        assertEquals("es-419", File(play, "default-language.txt").readText().trim())
        val notes = File(play, "release-notes/es-419/internal.txt").readText()
        assertTrue(notes.isNotBlank())
        assertTrue(notes.codePointCount(0, notes.length) <= RELEASE_NOTES_LIMIT, "notas de versión > $RELEASE_NOTES_LIMIT")
    }

    @Test
    fun `la ficha de Android no promete funciones que solo existen en Apple`() {
        val forbidden = listOf("icloud", "llavero", "keychain", "ipad", "pdf")
        listOf("es-419", "es-ES", "en-US").forEach { language ->
            val text = File(play, "listings/$language/full-description.txt").readText().lowercase()
            forbidden.forEach { word -> assertFalse(word in text, "$language menciona «$word»") }
        }
    }

    @Test
    fun `es-ES es copia exacta de es-419`() {
        LIMITS.keys.forEach { file ->
            assertEquals(File(play, "listings/es-419/$file").readText(), File(play, "listings/es-ES/$file").readText(), file)
        }
    }

    private companion object {
        /** Límites de Play Console (caracteres). */
        val LIMITS = mapOf("title.txt" to 30, "short-description.txt" to 80, "full-description.txt" to 4_000)
        const val RELEASE_NOTES_LIMIT = 500
    }
}
