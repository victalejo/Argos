package com.iaportafolio.argos.ui

import com.iaportafolio.argos.testing.transfer
import com.iaportafolio.argos.ui.importer.ImportLink
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** Filtro del intent de deep link antes de decodificar nada. */
class ImportLinkTest {

    private val link = transfer().urlString()

    @Test
    fun `acepta un VIEW con un enlace argos add-server`() {
        assertEquals(link, ImportLink.fromIntent(ImportLink.ACTION_VIEW, link))
    }

    @Test
    fun `el esquema y la acción no distinguen mayúsculas`() {
        val upper = link.replace("argos://add-server", "ARGOS://Add-Server")
        assertEquals(upper, ImportLink.fromIntent(ImportLink.ACTION_VIEW, upper))
    }

    @Test
    fun `ignora otras acciones o un intent sin datos`() {
        assertNull(ImportLink.fromIntent("android.intent.action.MAIN", link))
        assertNull(ImportLink.fromIntent("com.iaportafolio.argos.OPEN_AGENT_CHAT", link))
        assertNull(ImportLink.fromIntent(null, link))
        assertNull(ImportLink.fromIntent(ImportLink.ACTION_VIEW, null))
    }

    @Test
    fun `rechaza otros esquemas y acciones`() {
        assertNull(ImportLink.fromIntent(ImportLink.ACTION_VIEW, "https://add-server?d=abc"))
        assertNull(ImportLink.fromIntent(ImportLink.ACTION_VIEW, "argos://open?d=abc"))
        assertNull(ImportLink.fromIntent(ImportLink.ACTION_VIEW, "argos://add-server-evil?d=abc"))
        assertNull(ImportLink.fromIntent(ImportLink.ACTION_VIEW, "argos://add-server.evil.com/?d=abc"))
    }

    @Test
    fun `rechaza un enlace demasiado largo antes de decodificarlo`() {
        val long = "argos://add-server?d=" + "A".repeat(ImportLink.MAX_LENGTH)
        assertNull(ImportLink.fromIntent(ImportLink.ACTION_VIEW, long))
        val limit = "argos://add-server?d=".let { it + "A".repeat(ImportLink.MAX_LENGTH - it.length) }
        assertEquals(limit, ImportLink.fromIntent(ImportLink.ACTION_VIEW, limit))
    }

    @Test
    fun `rechaza espacios y caracteres de control`() {
        assertNull(ImportLink.fromIntent(ImportLink.ACTION_VIEW, "$link\n"))
        assertNull(ImportLink.fromIntent(ImportLink.ACTION_VIEW, "argos://add-server?d=a b"))
        assertNull(ImportLink.fromIntent(ImportLink.ACTION_VIEW, "argos://add-server?d=\u0000"))
    }
}
