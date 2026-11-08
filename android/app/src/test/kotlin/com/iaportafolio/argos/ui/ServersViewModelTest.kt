@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.ui

import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.agent.ClaudeAgentCommand
import com.iaportafolio.argos.data.AgentPermissionStore
import com.iaportafolio.argos.data.SecretKind
import com.iaportafolio.argos.testing.InMemoryAgentPermissionBackend
import com.iaportafolio.argos.testing.FakeServiceProvider
import com.iaportafolio.argos.testing.InMemorySecretStore
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.InMemoryTrustStore
import com.iaportafolio.argos.testing.MainDispatcherExtension
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.servers.ServersViewModel
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.RegisterExtension
import java.io.IOException
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ServersViewModelTest {

    private val agentPermissions = AgentPermissionStore(InMemoryAgentPermissionBackend())

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val repository = InMemoryServerRepository(listOf(server(id = "A"), server(id = "B", name = "prod", host = "prod.example.com")))
    private val secrets = InMemorySecretStore()
    private val trust = InMemoryTrustStore(mapOf("dev.example.com:22" to "SHA256:a", "prod.example.com:22" to "SHA256:b"))
    private val provider = FakeServiceProvider()

    private fun TestScope.viewModel() =
        ServersViewModel(repository, secrets, trust, provider, agentPermissions, main.dispatcher).also { advanceUntilIdle() }

    @Test
    fun `expone la lista del repositorio y sus cambios`() = runTest(main.dispatcher) {
        val vm = viewModel()
        assertEquals(listOf("A", "B"), vm.state.value.servers.map { it.id })
        repository.upsert(server(id = "C"))
        advanceUntilIdle()
        assertEquals(listOf("A", "B", "C"), vm.state.value.servers.map { it.id })
    }

    @Test
    fun `borrar pide confirmación y cancelar no borra`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.requestDelete(server(id = "A"))
        assertEquals("A", vm.state.value.pendingDeletion?.id)
        vm.cancelDelete()
        advanceUntilIdle()
        assertNull(vm.state.value.pendingDeletion)
        assertEquals(2, repository.servers.value.size)
    }

    @Test
    fun `confirmar borra servidor, secretos, huella y conexión`() = runTest(main.dispatcher) {
        secrets.write("B", SecretKind.PASSWORD, "pw")
        val vm = viewModel()
        vm.requestDelete(repository.servers.value[1])
        vm.confirmDelete()
        advanceUntilIdle()

        assertEquals(listOf("A"), vm.state.value.servers.map { it.id })
        assertEquals(listOf("B"), secrets.deletedAll)
        assertNull(trust.known["prod.example.com:22"])
        assertEquals(listOf("B"), provider.invalidated)
        assertNull(vm.state.value.pendingDeletion)
    }

    @Test
    fun `no olvida la huella si otro servidor comparte host y puerto`() = runTest(main.dispatcher) {
        repository.upsert(server(id = "A2", host = "dev.example.com"))
        val vm = viewModel()
        vm.requestDelete(server(id = "A"))
        vm.confirmDelete()
        advanceUntilIdle()
        assertEquals("SHA256:a", trust.known["dev.example.com:22"])
    }

    @Test
    fun `un fallo al borrar se muestra`() = runTest(main.dispatcher) {
        repository.failWrites = IOException("Disco lleno")
        val vm = viewModel()
        vm.requestDelete(server(id = "A"))
        vm.confirmDelete()
        advanceUntilIdle()
        assertEquals(UiText.Plain("Disco lleno"), vm.state.value.message)
        assertTrue(secrets.deletedAll.isEmpty())
    }

    @Test
    fun `olvidar host key borra la huella, invalida la conexión y avisa`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.forgetHostKey(server(id = "A"))
        advanceUntilIdle()
        assertNull(trust.known["dev.example.com:22"])
        assertEquals(listOf("A"), provider.invalidated)
        assertEquals(UiText.res(R.string.host_key_forgotten, "dev"), vm.state.value.message)
        vm.messageShown()
        assertNull(vm.state.value.message)
    }

    @Test
    fun `el ajuste global de permisos arranca en todos los permisos y se guarda`() = runTest(main.dispatcher) {
        val vm = viewModel()
        assertEquals(ClaudeAgentCommand.PermissionMode.BYPASS_PERMISSIONS, vm.state.value.agentPermissionMode)

        vm.setAgentPermissionMode(ClaudeAgentCommand.PermissionMode.DEFAULT)

        assertEquals(ClaudeAgentCommand.PermissionMode.DEFAULT, vm.state.value.agentPermissionMode)
        assertEquals(ClaudeAgentCommand.PermissionMode.DEFAULT, agentPermissions.globalMode())
    }
}
