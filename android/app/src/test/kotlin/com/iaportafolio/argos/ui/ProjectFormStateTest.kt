package com.iaportafolio.argos.ui

import com.iaportafolio.argos.core.projects.MacCheckout
import com.iaportafolio.argos.core.projects.ProjectError
import com.iaportafolio.argos.testing.project
import com.iaportafolio.argos.ui.projects.ProjectFormMode
import com.iaportafolio.argos.ui.projects.ProjectFormState
import com.iaportafolio.argos.ui.projects.StartupChoice
import org.junit.jupiter.api.Test
import java.time.Instant
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ProjectFormStateTest {

    @Test
    fun `comando de arranque guardado a opción del formulario y de vuelta`() {
        assertEquals(StartupChoice.Default, StartupChoice.of(null))
        assertEquals(StartupChoice.Preset(""), StartupChoice.of("   "))
        assertEquals(StartupChoice.Preset("cc --continue"), StartupChoice.of("cc --continue"))
        assertEquals(StartupChoice.Custom, StartupChoice.of("npm run dev"))

        val custom = ProjectFormState.forEdit(project(1, "a", startupCommand = "npm run dev"), emptyList(), "cc")
        assertEquals("npm run dev", custom.customCommand)
        assertEquals("npm run dev", custom.startupCommand)
        assertNull(custom.copy(command = StartupChoice.Default).startupCommand)
        assertEquals("", custom.copy(command = StartupChoice.Preset("")).startupCommand)
    }

    @Test
    fun `validación en vivo sin error para el nombre vacío`() {
        val empty = ProjectFormState.forNew(emptyList(), "cc")
        assertNull(empty.nameError)
        assertFalse(empty.canSubmit)
        assertTrue(empty.copy(name = "-x").nameError.orEmpty().isNotEmpty())
        assertTrue(empty.copy(group = "a.b").groupError.orEmpty().isNotEmpty())
        assertNull(empty.copy(group = "  ").groupError)
        assertEquals(ProjectError.InvalidPath.message, empty.copy(path = "~/x").pathError)
        assertTrue(empty.copy(name = "x", path = "/x").canSubmit)
        assertFalse(empty.copy(name = "x", path = "/x", isSubmitting = true).canSubmit)
    }

    @Test
    fun `editar conserva id, fecha y la marca de enviado al Mac`() {
        val checkout = MacCheckout("Mac de Víctor", "MAC1", Instant.ofEpochSecond(1_700_000_100))
        val original = project(1, "api", group = "web").copy(macCheckout = checkout)
        val edited = ProjectFormState.forEdit(original, listOf("web"), "cc").copy(name = "backend").toProject()
        assertEquals(original.id, edited.id)
        assertEquals(original.createdAt, edited.createdAt)
        assertEquals(checkout, edited.macCheckout)
        assertEquals("backend", edited.name)
        assertFalse(ProjectFormState.forEdit(original, listOf("web"), "cc").isNewGroup)
    }

    @Test
    fun `convertir separa grupo y nombre y adopta la sesión`() {
        val grouped = ProjectFormState.forConvert("tmh/web", emptyList(), "cc")
        assertEquals("web", grouped.name)
        assertEquals("tmh", grouped.group)
        assertEquals("tmh/web", grouped.adoptedSession)
        assertTrue(grouped.mode is ProjectFormMode.Convert)

        val plain = ProjectFormState.forConvert("main", emptyList(), "cc")
        assertEquals("main", plain.name)
        assertEquals("", plain.group)
        assertNull(ProjectFormState.forNew(emptyList(), "cc").adoptedSession)
        assertEquals("app", ProjectFormState.folderName("/srv/app/"))
    }
}
