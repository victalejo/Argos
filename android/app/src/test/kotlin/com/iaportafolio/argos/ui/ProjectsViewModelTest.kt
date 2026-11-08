@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.ui

import app.cash.turbine.test
import com.iaportafolio.argos.core.HostKeyMismatchException
import com.iaportafolio.argos.core.SSHServiceError
import com.iaportafolio.argos.core.projects.ProjectConfirmation
import com.iaportafolio.argos.core.projects.ProjectError
import com.iaportafolio.argos.core.projects.ProjectListing
import com.iaportafolio.argos.core.projects.ProjectStatusFilter
import com.iaportafolio.argos.testing.FakeServiceProvider
import com.iaportafolio.argos.testing.InMemoryProjectPreferences
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.InMemoryTrustStore
import com.iaportafolio.argos.testing.MainDispatcherExtension
import com.iaportafolio.argos.testing.project
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.testing.session
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.projects.ProjectFormMode
import com.iaportafolio.argos.ui.projects.ProjectsDialog
import com.iaportafolio.argos.ui.projects.ProjectsEvent
import com.iaportafolio.argos.ui.projects.ProjectsViewModel
import com.iaportafolio.argos.ui.projects.StartupChoice
import com.iaportafolio.argos.ui.sessions.ConnectStep
import com.iaportafolio.argos.ui.sessions.SessionDialog
import com.iaportafolio.argos.ui.sessions.SessionsLoad
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.RegisterExtension
import java.io.IOException
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ProjectsViewModelTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val repository = InMemoryServerRepository(listOf(server()))
    private val provider = FakeServiceProvider()
    private val ssh get() = provider.service
    private val trust = InMemoryTrustStore(mapOf("dev.example.com:22" to "SHA256:viejo"))
    private val preferences = InMemoryProjectPreferences()

    private fun TestScope.viewModel(serverId: String = "S1") =
        ProjectsViewModel(serverId, repository, provider, trust, preferences, main.dispatcher)

    private fun TestScope.loaded(): ProjectsViewModel = viewModel().also { advanceUntilIdle() }

    private fun ProjectsViewModel.form() = assertIs<ProjectsDialog.Form>(state.value.dialog).form

    private fun ProjectsViewModel.looseNames() = state.value.looseSessions.map { it.name }

    // MARK: - Conexión (migrado de SessionsViewModelTest)

    @Test
    fun `conecta, arranca tmux, lista sesiones y lee projects json`() = runTest(main.dispatcher) {
        ssh.sessions = listOf(session("main"), session("web/api"))
        ssh.projects = listOf(project(1, "api", group = "web"))
        val vm = loaded()

        val state = vm.state.value
        assertEquals(SessionsLoad.Loaded, state.load)
        assertEquals("dev", state.serverName)
        assertEquals(listOf("isTmuxInstalled", "configExists", "clipboard", "list", "loadProjects"), ssh.calls)
        assertEquals(listOf("web"), state.sections.map { it.name })
        assertTrue(state.sections.single().entries.single().isRunning)
        assertEquals(listOf("main"), vm.looseNames())
    }

    @Test
    fun `emite los pasos de conexión y luego la lista`() = runTest(main.dispatcher) {
        val gate = CompletableDeferred<Unit>()
        ssh.listGate = gate
        val vm = viewModel()

        vm.state.test {
            assertEquals(SessionsLoad.Connecting(ConnectStep.VERIFYING), awaitItem().load)
            val listing = awaitItem()
            assertEquals(SessionsLoad.Connecting(ConnectStep.LOADING), listing.load)
            assertTrue(listing.isBusy)
            gate.complete(Unit)
            assertEquals(SessionsLoad.Loaded, awaitItem().load)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `sin tmux y con sudo lo instala y configura`() = runTest(main.dispatcher) {
        ssh.tmuxInstalled = false
        ssh.canSudo = true
        ssh.configExists = false
        loaded()
        assertEquals(
            listOf("isTmuxInstalled", "canSudo", "install", "configExists", "writeConfig", "clipboard", "list", "loadProjects"),
            ssh.calls,
        )
    }

    @Test
    fun `sin tmux y sin sudo muestra la instrucción manual`() = runTest(main.dispatcher) {
        ssh.tmuxInstalled = false
        val vm = loaded()
        assertEquals(SessionsLoad.TmuxMissing, vm.state.value.load)
        assertTrue("list" !in ssh.calls)
    }

    @Test
    fun `TmuxNotInstalled del servicio también es tmux ausente`() = runTest(main.dispatcher) {
        ssh.listError = SSHServiceError.TmuxNotInstalled()
        assertEquals(SessionsLoad.TmuxMissing, loaded().state.value.load)
    }

    @Test
    fun `error de red se muestra con userMessage y reintentar reconecta`() = runTest(main.dispatcher) {
        provider.error = IOException("Conexión rechazada")
        val vm = loaded()
        assertEquals(SessionsLoad.Failed("Conexión rechazada"), vm.state.value.load)

        provider.error = null
        vm.load()
        advanceUntilIdle()
        assertEquals(SessionsLoad.Loaded, vm.state.value.load)
    }

    @Test
    fun `huella cambiada (también envuelta) ofrece olvidarla y reintentar`() = runTest(main.dispatcher) {
        val mismatch = HostKeyMismatchException("dev.example.com:22", "SHA256:viejo", "SHA256:nuevo")
        provider.error = IOException("transporte", mismatch)
        val vm = loaded()
        val state = assertIs<SessionsLoad.HostKeyChanged>(vm.state.value.load)
        assertTrue(state.message.contains("SHA256:nuevo"))

        provider.error = null
        vm.forgetHostKeyAndRetry()
        advanceUntilIdle()

        assertNull(trust.known["dev.example.com:22"])
        assertEquals(listOf("S1"), provider.invalidated)
        assertEquals(SessionsLoad.Loaded, vm.state.value.load)
    }

    @Test
    fun `servidor inexistente`() = runTest(main.dispatcher) {
        val vm = viewModel(serverId = "nope").also { advanceUntilIdle() }
        assertEquals(SessionsLoad.ServerMissing, vm.state.value.load)
    }

    @Test
    fun `projects json inválido no tumba la lista de sesiones`() = runTest(main.dispatcher) {
        ssh.sessions = listOf(session("main"))
        ssh.projectsError = ProjectError.InvalidFile
        val vm = loaded()
        assertEquals(SessionsLoad.Loaded, vm.state.value.load)
        assertEquals(ProjectError.InvalidFile.message, vm.state.value.projectsError)
        assertEquals(listOf("main"), vm.looseNames())

        ssh.projectsError = null
        vm.refresh()
        advanceUntilIdle()
        assertNull(vm.state.value.projectsError)
    }

    @Test
    fun `refresh con la lista visible solo re-lista y conserva la lista si falla`() = runTest(main.dispatcher) {
        ssh.sessions = listOf(session("main"))
        val vm = loaded()
        ssh.calls.clear()

        ssh.sessions = listOf(session("main"), session("otra"))
        vm.refresh()
        advanceUntilIdle()
        assertEquals(listOf("list", "loadProjects"), ssh.calls)
        assertEquals(listOf("main", "otra"), vm.looseNames())
        assertFalse(vm.state.value.isRefreshing)

        ssh.listError = IOException("se cayó")
        vm.refresh()
        advanceUntilIdle()
        assertEquals(SessionsLoad.Loaded, vm.state.value.load)
        assertEquals(listOf("main", "otra"), vm.looseNames())
        assertEquals(UiText.Plain("se cayó"), vm.state.value.message)
    }

    @Test
    fun `el nombre del servidor sigue a las ediciones`() = runTest(main.dispatcher) {
        val vm = loaded()
        repository.upsert(server(name = "producción"))
        advanceUntilIdle()
        assertEquals("producción", vm.state.value.serverName)
    }

    // MARK: - Listado, filtro y grupos

    @Test
    fun `agrupa con ProjectListing, General al final, y filtra por estado`() = runTest(main.dispatcher) {
        ssh.projects = listOf(
            project(1, "zeta"),
            project(2, "api", group = "web"),
            project(3, "front", group = "web"),
            project(4, "docs", group = "Alpha"),
        )
        ssh.sessions = listOf(session("web/api"), session("web/front", attached = true), session("suelta"))
        val vm = loaded()
        assertEquals(listOf("Alpha", "web", "General"), vm.state.value.sections.map { it.name })

        vm.setFilter(ProjectStatusFilter.STOPPED)
        advanceUntilIdle()
        assertEquals(listOf("docs", "zeta"), vm.state.value.sections.flatMap { s -> s.entries.map { it.project.name } })
        assertEquals(emptyList(), vm.looseNames())

        vm.setFilter(ProjectStatusFilter.DORMANT)
        advanceUntilIdle()
        assertEquals(listOf("api"), vm.state.value.sections.flatMap { s -> s.entries.map { it.project.name } })
        assertEquals(listOf("suelta"), vm.looseNames())

        vm.setFilter(ProjectStatusFilter.BACKGROUND)
        advanceUntilIdle()
        assertEquals(listOf("front"), vm.state.value.sections.flatMap { s -> s.entries.map { it.project.name } })
        assertEquals(1, vm.state.value.filterCounts[ProjectStatusFilter.BACKGROUND])
        assertEquals(5, vm.state.value.filterCounts[ProjectStatusFilter.ALL])
        assertEquals(ProjectStatusFilter.BACKGROUND, preferences.preferences.value.statusFilter)
    }

    @Test
    fun `colapsar un grupo lo persiste y oculta sus entradas pero no la cabecera`() = runTest(main.dispatcher) {
        ssh.projects = listOf(project(1, "api", group = "web"), project(2, "b"))
        val vm = loaded()
        vm.toggleGroup("web")
        advanceUntilIdle()

        val web = vm.state.value.sections.first { it.name == "web" }
        assertTrue(web.isCollapsed)
        assertEquals(setOf("S1/web"), preferences.preferences.value.collapsed.keys)
        assertFalse(vm.state.value.sections.first { it.name == "General" }.isCollapsed)

        vm.toggleGroup("web")
        advanceUntilIdle()
        assertFalse(vm.state.value.sections.first { it.name == "web" }.isCollapsed)
    }

    // MARK: - Abrir / detener / quitar

    @Test
    fun `abrir un proyecto en marcha solo navega`() = runTest(main.dispatcher) {
        ssh.projects = listOf(project(1, "api"))
        ssh.sessions = listOf(session("api"))
        val vm = loaded()
        vm.events.test {
            vm.openProject(vm.state.value.listing.entries.single())
            assertEquals(ProjectsEvent.OpenProject(project(1, "api").id), awaitItem())
        }
        assertTrue(ssh.calls.none { it.startsWith("start:") })
    }

    @Test
    fun `abrir un proyecto detenido lo arranca con el comando por defecto y navega`() = runTest(main.dispatcher) {
        ssh.projects = listOf(project(1, "api", group = "web"), project(2, "docs", startupCommand = ""))
        val vm = loaded()
        vm.events.test {
            vm.openProject(vm.state.value.listing.entries.first { it.project.name == "api" })
            assertEquals(project(1, "api").id, vm.state.value.busyProjectId)
            advanceUntilIdle()
            assertEquals(ProjectsEvent.OpenProject(project(1, "api").id), awaitItem())

            vm.openProject(vm.state.value.listing.entries.first { it.project.name == "docs" })
            advanceUntilIdle()
            awaitItem()
        }
        assertTrue("start:web/api|/srv/api|cc --continue" in ssh.calls)
        // `""` = no lanzar nada.
        assertTrue("start:docs|/srv/docs|null" in ssh.calls)
        assertNull(vm.state.value.busyProjectId)
        assertTrue(vm.state.value.listing.entries.first { it.project.name == "api" }.isRunning)
    }

    @Test
    fun `carpeta inexistente al abrir se avisa con el mensaje de core`() = runTest(main.dispatcher) {
        ssh.projects = listOf(project(1, "api"))
        ssh.startError = ProjectError.MissingFolder("/srv/api")
        val vm = loaded()
        vm.events.test {
            vm.openProject(vm.state.value.listing.entries.single())
            advanceUntilIdle()
            expectNoEvents()
        }
        assertEquals(UiText.Plain(ProjectError.MissingFolder("/srv/api").message.orEmpty()), vm.state.value.message)
        assertNull(vm.state.value.busyProjectId)
    }

    @Test
    fun `detener pide confirmación con el texto de core y mata la sesión`() = runTest(main.dispatcher) {
        ssh.projects = listOf(project(1, "api"))
        ssh.sessions = listOf(session("api"))
        val vm = loaded()

        vm.requestStop(project(1, "api"))
        val dialog = assertIs<ProjectsDialog.Confirm>(vm.state.value.dialog)
        assertIs<ProjectConfirmation.Stop>(dialog.confirmation)
        assertEquals("¿Detener 'api'?", dialog.confirmation.title)

        vm.confirmProjectAction()
        advanceUntilIdle()
        assertTrue("stop:api" in ssh.calls)
        assertNull(vm.state.value.dialog)
        assertFalse(vm.state.value.listing.entries.single().isRunning)
        assertEquals(1, ssh.projects.size) // el proyecto se conserva
    }

    @Test
    fun `quitar relee projects json actual y conserva la sesión como suelta`() = runTest(main.dispatcher) {
        ssh.projects = listOf(project(1, "api"))
        ssh.sessions = listOf(session("api"))
        val vm = loaded()
        // Otro cliente añadió un proyecto mientras tanto: no se pisa.
        ssh.projects = ssh.projects + project(2, "nuevo")

        vm.requestRemove(project(1, "api"))
        vm.dismissProjectDialog()
        assertNull(vm.state.value.dialog)
        vm.requestRemove(project(1, "api"))
        vm.confirmProjectAction()
        advanceUntilIdle()

        assertEquals(listOf("nuevo"), ssh.projects.map { it.name })
        assertEquals(listOf("api"), vm.looseNames())
    }

    @Test
    fun `un fallo al quitar se avisa`() = runTest(main.dispatcher) {
        ssh.projects = listOf(project(1, "api"))
        val vm = loaded()
        ssh.saveError = IOException("disco lleno")
        vm.requestRemove(project(1, "api"))
        vm.confirmProjectAction()
        advanceUntilIdle()
        assertEquals(UiText.Plain("disco lleno"), vm.state.value.message)
        assertNull(vm.state.value.dialog)
    }

    // MARK: - Crear / editar / convertir

    @Test
    fun `crear valida en vivo con los mensajes de core y guarda al final`() = runTest(main.dispatcher) {
        ssh.projects = listOf(project(1, "api", group = "web"))
        val vm = loaded()
        vm.openNewProject()
        assertEquals(listOf("web"), vm.form().existingGroups)
        assertFalse(vm.form().canSubmit)

        vm.onFormName("mal:nombre")
        assertNotNull(vm.form().nameError)
        vm.onFormName("a/b")
        assertTrue(vm.form().nameError.orEmpty().contains("'/'"))
        vm.onFormName("blog")
        assertNull(vm.form().nameError)
        vm.onFormPath("relativa")
        assertEquals(ProjectError.InvalidPath.message, vm.form().pathError)
        assertFalse(vm.form().canSubmit)

        vm.onFormPath(" /srv/blog ")
        vm.onFormGroup("nuevo")
        assertTrue(vm.form().isNewGroup)
        vm.onFormCommand(StartupChoice.Custom)
        assertFalse(vm.form().canSubmit)
        vm.onFormCustomCommand("npm run dev")
        assertTrue(vm.form().canSubmit)

        vm.submitForm()
        advanceUntilIdle()
        assertNull(vm.state.value.dialog)
        val saved = ssh.projects.last()
        assertEquals("blog", saved.name)
        assertEquals("nuevo", saved.group)
        assertEquals("/srv/blog", saved.path)
        assertEquals("npm run dev", saved.startupCommand)
        assertEquals(listOf("nuevo", "web"), vm.state.value.sections.map { it.name })
    }

    @Test
    fun `duplicado con una sesión suelta se rechaza dentro del formulario`() = runTest(main.dispatcher) {
        ssh.sessions = listOf(session("web/api"))
        val vm = loaded()
        vm.openNewProject()
        vm.onFormName("api")
        vm.onFormGroup("web")
        vm.onFormPath("/srv/api")
        vm.submitForm()
        advanceUntilIdle()

        val form = vm.form()
        assertEquals(ProjectError.DuplicateName("web/api").message, form.error)
        assertFalse(form.isSubmitting)
        assertTrue("saveProjects" !in ssh.calls)
    }

    @Test
    fun `editar un proyecto en marcha renombra su sesión y conserva id y fecha`() = runTest(main.dispatcher) {
        val original = project(1, "api", group = "web", startupCommand = "cc")
        ssh.projects = listOf(original)
        ssh.sessions = listOf(session("web/api"))
        val vm = loaded()

        vm.openEditProject(original)
        assertIs<ProjectFormMode.Edit>(vm.form().mode)
        assertEquals(StartupChoice.Preset("cc"), vm.form().command)
        vm.onFormName("backend")
        vm.onFormCommand(StartupChoice.Default)
        vm.submitForm()
        advanceUntilIdle()

        assertTrue("rename:web/api->web/backend" in ssh.calls)
        val saved = ssh.projects.single()
        assertEquals(original.id, saved.id)
        assertEquals(original.createdAt, saved.createdAt)
        assertNull(saved.startupCommand)
        assertTrue(vm.state.value.listing.entries.single().isRunning)
    }

    @Test
    fun `convertir una sesión suelta propone nombre, grupo y carpeta y la adopta`() = runTest(main.dispatcher) {
        ssh.sessions = listOf(session("tmh/web"))
        ssh.firstPanePaths = mapOf("tmh/web" to "/home/v/web")
        val vm = loaded()

        vm.openConvert(session("tmh/web"))
        assertTrue(vm.form().isPrefilling)
        advanceUntilIdle()
        val form = vm.form()
        assertEquals("web", form.name)
        assertEquals("tmh", form.group)
        assertEquals("/home/v/web", form.path)
        assertFalse(form.isPrefilling)

        vm.submitForm()
        advanceUntilIdle()
        assertNull(vm.state.value.dialog)
        assertEquals("tmh/web", ssh.projects.single().sessionName)
        assertEquals(emptyList(), vm.looseNames())
    }

    @Test
    fun `elegir carpeta en el selector propone el nombre si está vacío`() = runTest(main.dispatcher) {
        val vm = loaded()
        vm.openNewProject()
        vm.onFolderPicked("/home/v/mi-app/")
        assertEquals("mi-app", vm.form().name)
        assertEquals("/home/v/mi-app/", vm.form().path)
        vm.onFolderPicked("/otra")
        assertEquals("mi-app", vm.form().name)
    }

    // MARK: - Importar

    @Test
    fun `importar marca todo, permite desmarcar y guarda los elegidos`() = runTest(main.dispatcher) {
        ssh.sessions = listOf(session("a"), session("g/b"), session("sin-carpeta"))
        ssh.firstPanePaths = mapOf("a" to "/srv/a", "g/b" to "/srv/b")
        val vm = loaded()

        vm.openImport()
        advanceUntilIdle()
        val import = assertIs<ProjectsDialog.Import>(vm.state.value.dialog).state
        assertEquals(listOf("a", "g/b"), import.candidates.map { it.sessionName })
        assertEquals(2, import.selected.size)

        vm.toggleImportCandidate(import.candidates.first().id)
        vm.confirmImport()
        advanceUntilIdle()
        assertNull(vm.state.value.dialog)
        assertEquals(listOf("g/b"), ssh.projects.map { it.sessionName })
        assertEquals(listOf("a", "sin-carpeta"), vm.looseNames())
    }

    @Test
    fun `un fallo leyendo carpetas se muestra en el diálogo de importar`() = runTest(main.dispatcher) {
        ssh.sessions = listOf(session("a"))
        ssh.firstPaneError = IOException("tmux murió")
        val vm = loaded()
        vm.openImport()
        advanceUntilIdle()
        val import = assertIs<ProjectsDialog.Import>(vm.state.value.dialog).state
        assertEquals("tmux murió", import.error)
        assertFalse(import.canImport)
    }

    @Test
    fun `importing de core no duplica nombres de sesión ya existentes`() = runTest(main.dispatcher) {
        // Garantía de ProjectLifecycle.importing que el ViewModel usa tal cual.
        val existing = listOf(project(1, "a"))
        val candidates = listOf(project(2, "a"), project(3, "b"))
        assertEquals(listOf("a", "b"), com.iaportafolio.argos.core.projects.ProjectLifecycle.importing(existing, candidates).map { it.name })
        assertEquals(emptyList(), ProjectListing.build(existing, emptyList()).looseSessions)
    }

    // MARK: - Sesiones sueltas (migrado)

    @Test
    fun `crear sesión valida en vivo, crea, recarga y la abre`() = runTest(main.dispatcher) {
        val vm = loaded()
        vm.openCreateSession()
        vm.onDialogTextChange("mal:nombre")
        val invalid = assertIs<SessionDialog.Create>(vm.state.value.sessionDialog)
        assertNotNull(invalid.error)

        vm.submitDialog()
        assertTrue("create:mal:nombre" !in ssh.calls)

        vm.events.test {
            vm.onDialogTextChange("  web/api  ")
            assertNull((vm.state.value.sessionDialog as SessionDialog.Create).error)
            vm.submitDialog()
            advanceUntilIdle()
            assertEquals(ProjectsEvent.OpenSession("web/api"), awaitItem())
        }
        assertTrue("create:web/api" in ssh.calls)
        assertNull(vm.state.value.sessionDialog)
        assertEquals(listOf("web/api"), vm.looseNames())
    }

    @Test
    fun `un error al crear sesión se queda en el diálogo`() = runTest(main.dispatcher) {
        val vm = loaded()
        ssh.managementError = SSHServiceError.CommandFailed(1, "duplicate session: main")
        vm.openCreateSession()
        vm.onDialogTextChange("main")
        vm.submitDialog()
        advanceUntilIdle()

        val dialog = assertIs<SessionDialog.Create>(vm.state.value.sessionDialog)
        assertFalse(dialog.isSubmitting)
        assertTrue(dialog.error.orEmpty().contains("duplicate session"))
    }

    @Test
    fun `renombrar al mismo nombre solo cierra y a otro renombra`() = runTest(main.dispatcher) {
        ssh.sessions = listOf(session("main"))
        val vm = loaded()
        vm.openRenameSession(session("main"))
        vm.submitDialog()
        assertNull(vm.state.value.sessionDialog)
        assertTrue(ssh.calls.none { it.startsWith("rename") })

        vm.openRenameSession(session("main"))
        vm.onDialogTextChange("principal")
        vm.submitDialog()
        advanceUntilIdle()
        assertTrue("rename:main->principal" in ssh.calls)
        assertEquals(listOf("principal"), vm.looseNames())
    }

    @Test
    fun `cerrar sesión pide confirmación y un fallo se avisa sin perder la lista`() = runTest(main.dispatcher) {
        ssh.sessions = listOf(session("main"), session("b"))
        val vm = loaded()

        vm.requestKillSession(session("main"))
        assertIs<SessionDialog.ConfirmKill>(vm.state.value.sessionDialog)
        vm.dismissDialog()
        assertNull(vm.state.value.sessionDialog)
        assertTrue(ssh.calls.none { it.startsWith("kill") })

        vm.requestKillSession(session("main"))
        vm.confirmKill()
        advanceUntilIdle()
        assertEquals(listOf("b"), vm.looseNames())

        ssh.managementError = IOException("sin permiso")
        vm.requestKillSession(session("b"))
        vm.confirmKill()
        advanceUntilIdle()
        assertEquals(UiText.Plain("sin permiso"), vm.state.value.message)
        assertEquals(SessionsLoad.Loaded, vm.state.value.load)

        vm.messageShown()
        assertNull(vm.state.value.message)
    }
}
