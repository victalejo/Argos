package com.iaportafolio.argos.ui

import com.iaportafolio.argos.ui.about.AboutLinks
import com.iaportafolio.argos.ui.about.versionLabel
import com.iaportafolio.argos.ui.files.SafeLinkPolicy
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class AboutLinksTest {

    @Test
    fun `los enlaces de Acerca de son https y pasan la politica de enlaces seguros`() {
        listOf(AboutLinks.PRIVACY_POLICY, AboutLinks.SOURCE_CODE).forEach { link ->
            assertTrue(link.startsWith("https://"), link)
            assertTrue(SafeLinkPolicy.isAllowed(link), link)
        }
    }

    @Test
    fun `la politica de privacidad es la misma que la de la ficha de Apple`() {
        assertEquals("https://iaportafolio.com/privacidad#argos", AboutLinks.PRIVACY_POLICY)
    }

    @Test
    fun `la version muestra nombre y codigo`() {
        assertEquals("1.0.0 (1)", versionLabel("1.0.0", 1))
    }
}
