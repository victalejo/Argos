@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.ui

import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.agent.RemoteDirectoryListing
import com.iaportafolio.argos.core.projects.ProjectError
import com.iaportafolio.argos.testing.FakeFileService
import com.iaportafolio.argos.testing.FakeSSHService
import com.iaportafolio.argos.testing.FakeServiceProvider
import com.iaportafolio.argos.testing.InMemoryProjectPreferences
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.MainDispatcherExtension
import com.iaportafolio.argos.testing.SingleServiceProvider
import com.iaportafolio.argos.testing.project
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.testing.session
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.project.ProjectLoad
import com.iaportafolio.argos.ui.project.ProjectTab
import com.iaportafolio.argos.ui.project.ProjectViewModel
import com.iaportafolio.argos.ui.projects.FolderPickerViewModel
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.RegisterExtension
import java.io.IOException
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ProjectViewModelTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val repository = InMemoryServerRepository(listOf(server()))
    private val provider = FakeServiceProvider()
    private val ssh get() = provider.service
    private val api = project(1, "api", group = "web")

    private fun TestScope.loaded(projectId: String = api.id) =
        ProjectViewModel("S1", projectId, repository, provider, InMemoryProjectPreferences(), main.dispatcher)
            .also { advanceUntilIdle() }

    @Test
    fun `carga el proyecto y sabe si su sesión corre`() = runTest(main.dispatcher) {
        ssh.projects = listOf(api)
        ssh.sessions = listOf(session("web/api"))
        val vm = loaded()
        assertEquals(ProjectLoad.Loaded(api, isRunning = true), vm.state.value.load)
        assertEquals(ProjectTab.TERMINAL, vm.state.value.tab)
        vm.selectTab(ProjectTab.FILES)
        assertEquals(ProjectTab.FILES, vm.state.value.tab)
    }

    @Test
    fun `detenido ofrece arrancar y al arrancar queda en marcha`() = runTest(main.dispatcher) {
        ssh.projects = listOf(api)
        val vm = loaded()
        assertEquals(ProjectLoad.Loaded(api, isRunning = false), vm.state.value.load)

        vm.start()
        assertTrue(vm.state.value.isStarting)
        advanceUntilIdle()
        assertTrue("start:web/api|/srv/api|cc --continue" in ssh.calls)
        assertEquals(ProjectLoad.Loaded(api, isRunning = true), vm.state.value.load)
        assertFalse(vm.state.value.isStarting)
    }

    @Test
    fun `un fallo al arrancar se avisa sin perder el proyecto`() = runTest(main.dispatcher) {
        ssh.projects = listOf(api)
        ssh.startError = ProjectError.MissingFolder("/srv/api")
        val vm = loaded()
        vm.start()
        advanceUntilIdle()
        assertEquals(UiText.Plain(ProjectError.MissingFolder("/srv/api").message.orEmpty()), vm.state.value.message)
        assertEquals(ProjectLoad.Loaded(api, isRunning = false), vm.state.value.load)
    }

    @Test
    fun `proyecto quitado desde otro cliente y error de red`() = runTest(main.dispatcher) {
        assertEquals(ProjectLoad.Missing, loaded().state.value.load)

        provider.error = IOException("sin red")
        val failed = loaded()
        assertEquals(ProjectLoad.Failed(UiText.Plain("sin red")), failed.state.value.load)
        provider.error = null
        ssh.projects = listOf(api)
        failed.reload()
        advanceUntilIdle()
        assertIs<ProjectLoad.Loaded>(failed.state.value.load)
    }

    @Test
    fun `al recargar con el proyecto visible un fallo solo se avisa`() = runTest(main.dispatcher) {
        ssh.projects = listOf(api)
        val vm = loaded()
        provider.error = IOException("sin red")
        vm.reload()
        advanceUntilIdle()
        assertIs<ProjectLoad.Loaded>(vm.state.value.load)
        assertEquals(UiText.Plain("sin red"), vm.state.value.message)
        vm.messageShown()
        assertNull(vm.state.value.message)
    }

    // MARK: - Selector de carpetas

    private val files = FakeFileService()

    private fun TestScope.picker(service: com.iaportafolio.argos.core.SSHServicing = files) =
        FolderPickerViewModel("S1", repository, SingleServiceProvider(service), main.dispatcher)

    @Test
    fun `el selector empieza en el home y navega por subcarpetas y hacia arriba`() = runTest(main.dispatcher) {
        files.folders["~"] = RemoteDirectoryListing("/home/v", listOf("a", "b"))
        files.folders["/home/v/a"] = RemoteDirectoryListing("/home/v/a", emptyList())
        files.folders["/home"] = RemoteDirectoryListing("/home", listOf("v"))
        val vm = picker()
        vm.start("relativa")
        advanceUntilIdle()
        assertEquals("/home/v", vm.state.value.listing?.path)
        assertTrue(vm.state.value.canGoUp)

        vm.openChild("a")
        advanceUntilIdle()
        assertEquals("/home/v/a", vm.state.value.listing?.path)

        vm.goUp()
        files.folders["/home/v"] = RemoteDirectoryListing("/home/v", listOf("a", "b"))
        advanceUntilIdle()
        assertEquals("/home/v", vm.state.value.listing?.path)
    }

    @Test
    fun `el selector arranca en la carpeta ya escrita y la raíz no sube`() = runTest(main.dispatcher) {
        files.folders["/"] = RemoteDirectoryListing("/", listOf("srv"))
        val vm = picker()
        vm.start("/")
        advanceUntilIdle()
        assertFalse(vm.state.value.canGoUp)
        assertEquals("/", FolderPickerViewModel.parent("/srv"))
        assertEquals("/srv", FolderPickerViewModel.parent("/srv/app/"))
    }

    @Test
    fun `errores del selector visibles y reintentables, y servicio sin explorador`() = runTest(main.dispatcher) {
        files.foldersError = IOException("permiso denegado")
        val vm = picker()
        vm.start("")
        advanceUntilIdle()
        assertEquals(UiText.Plain("permiso denegado"), vm.state.value.error)

        files.foldersError = null
        files.folders["~"] = RemoteDirectoryListing("/home/v", emptyList())
        vm.retry()
        advanceUntilIdle()
        assertNull(vm.state.value.error)

        val legacy = picker(FakeSSHService())
        legacy.start("")
        advanceUntilIdle()
        assertEquals(UiText.res(R.string.files_unsupported), legacy.state.value.error)
    }
}
