package com.iaportafolio.argos.core.files

import com.iaportafolio.argos.core.files.HtmlPreviewPolicy.Decision
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Paridad con `ArgosTests/HTMLPreviewPolicyTests.swift` (commit c40ab9b). */
class HtmlPreviewPolicyTest {

    private fun decide(url: String?, link: Boolean = false, main: Boolean = true, remote: Boolean = false) =
        HtmlPreviewPolicy.decide(url, isUserLink = link, isMainFrame = main, allowsRemoteContent = remote)

    @Test
    fun `la carga inicial y las anclas se permiten`() {
        assertEquals(Decision.Allow, decide("about:blank"))
        assertEquals(Decision.Allow, decide("about:blank#seccion", link = true))
    }

    @Test
    fun `los enlaces del usuario se abren fuera solo si son http https o mailto`() {
        assertEquals(Decision.OpenExternally("https://ejemplo.com"), decide("https://ejemplo.com", link = true))
        assertEquals(Decision.OpenExternally("mailto:a@b.co"), decide("mailto:a@b.co", link = true))
        assertEquals(Decision.Cancel, decide("file:///etc/passwd", link = true))
        assertEquals(Decision.Cancel, decide("javascript:alert(1)", link = true))
        assertEquals(Decision.Cancel, decide("argos://algo", link = true))
    }

    @Test
    fun `la pagina nunca navega sola el documento principal`() {
        assertEquals(Decision.Cancel, decide("https://rastreo.com"))
        assertEquals(Decision.Cancel, decide("https://rastreo.com", remote = true))
        assertEquals(Decision.Cancel, decide("file:///etc/hosts"))
        assertEquals(Decision.Cancel, decide(null, link = true, remote = true))
        assertEquals(Decision.Cancel, decide("no es una url con espacios", link = true))
    }

    @Test
    fun `iframes remotos solo con el contenido externo permitido`() {
        assertEquals(Decision.Cancel, decide("https://youtube.com/embed/x", main = false))
        assertEquals(Decision.Allow, decide("https://youtube.com/embed/x", main = false, remote = true))
        assertEquals(Decision.Cancel, decide("file:///x", main = false, remote = true))
    }

    @Test
    fun `sin permiso solo se cargan recursos incrustados`() {
        assertTrue(HtmlPreviewPolicy.allowsResource("data:image/png;base64,AAAA", allowsRemoteContent = false))
        assertTrue(HtmlPreviewPolicy.allowsResource("about:blank", allowsRemoteContent = false))
        assertFalse(HtmlPreviewPolicy.allowsResource("https://rastreo.com/pixel.gif", allowsRemoteContent = false))
        assertTrue(HtmlPreviewPolicy.allowsResource("https://cdn.com/a.css", allowsRemoteContent = true))
        assertFalse(HtmlPreviewPolicy.allowsResource(null, allowsRemoteContent = true))
    }
}
