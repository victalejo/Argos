package com.iaportafolio.argos.core.projects

import com.iaportafolio.argos.core.tmux.TmuxSession
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ProjectSearchTest {

    private val project = Project(name = "Tienda Ñandú", group = "ia portafolio", path = "/srv/www/tienda")

    @Test
    fun `consulta vacia lo muestra todo`() {
        assertTrue(ProjectSearch.matches("", project))
        assertTrue(ProjectSearch.matches("   ", project))
    }

    @Test
    fun `sin distinguir mayusculas ni tildes, en nombre, grupo o carpeta`() {
        assertTrue(ProjectSearch.matches("nandu", project))
        assertTrue(ProjectSearch.matches("TIENDA", project))
        assertTrue(ProjectSearch.matches("portafolio", project))
        assertTrue(ProjectSearch.matches("srv/www", project))
        assertFalse(ProjectSearch.matches("blog", project))
    }

    @Test
    fun `todas las palabras deben aparecer`() {
        assertTrue(ProjectSearch.matches("ia tienda", project))
        assertFalse(ProjectSearch.matches("ia blog", project))
    }

    @Test
    fun `sesiones sueltas por su nombre`() {
        val session = TmuxSession("Pruebas/Rápidas", 1, false, Instant.EPOCH)
        assertTrue(ProjectSearch.matches("rapidas", session))
        assertFalse(ProjectSearch.matches("tienda", session))
    }
}
