@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.ui

import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.agent.AgentExecException
import com.iaportafolio.argos.core.agent.ClaudeAgentCommand.PermissionMode
import com.iaportafolio.argos.core.agent.ClaudeAuthStatus
import com.iaportafolio.argos.core.agent.PersistentAgentMeta
import com.iaportafolio.argos.core.agent.PersistentAgentScript
import com.iaportafolio.argos.data.AgentPermissionSelection
import com.iaportafolio.argos.data.AgentPermissionStore
import com.iaportafolio.argos.data.ClaudeTokenUnavailableException
import com.iaportafolio.argos.testing.AGENT_1
import com.iaportafolio.argos.testing.AGENT_2
import com.iaportafolio.argos.testing.AGENT_3
import com.iaportafolio.argos.testing.FakeAgentService
import com.iaportafolio.argos.testing.FakeSSHService
import com.iaportafolio.argos.testing.InMemoryAgentPermissionBackend
import com.iaportafolio.argos.testing.InMemoryClaudeTokens
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.MainDispatcherExtension
import com.iaportafolio.argos.testing.SECRET_TOKEN
import com.iaportafolio.argos.testing.SingleServiceProvider
import com.iaportafolio.argos.testing.agentInfo
import com.iaportafolio.argos.testing.networkDown
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.ui.agents.AgentListDialog
import com.iaportafolio.argos.ui.agents.AgentListEvent
import com.iaportafolio.argos.ui.agents.AgentListLoad
import com.iaportafolio.argos.ui.agents.AgentListViewModel
import com.iaportafolio.argos.ui.agents.ClaudeAvailability
import com.iaportafolio.argos.ui.common.UiText
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.RegisterExtension
import java.time.Instant
import java.util.Base64
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AgentListViewModelTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val repository = InMemoryServerRepository(listOf(server()))
    private val ssh = FakeAgentService()
    private val provider = SingleServiceProvider(ssh)
    private val tokens = InMemoryClaudeTokens()
    private val signedOut = ClaudeAuthStatus(loggedIn = false, subscriptionType = null, email = null)

    private val permissionsBackend = InMemoryAgentPermissionBackend()
    private val permissions = AgentPermissionStore(permissionsBackend)

    private fun viewModel(serverId: String = "S1") =
        AgentListViewModel(serverId, "api", "/srv/api", repository, provider, tokens, permissions, main.dispatcher)

    private fun TestScope.loaded() = viewModel().also { advanceUntilIdle() }

    /** Recoge los eventos del ViewModel durante todo el test. */
    private fun TestScope.eventsOf(vm: AgentListViewModel): List<AgentListEvent> {
        val events = mutableListOf<AgentListEvent>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { vm.events.toList(events) }
        return events
    }

    private fun messageRes(vm: AgentListViewModel) = (vm.state.value.message as? UiText.Resource)?.id

    @Test
    fun `solo lista los agentes de la carpeta del proyecto, el más nuevo primero`() = runTest(main.dispatcher) {
        ssh.agents = listOf(
            agentInfo(AGENT_1, createdAt = Instant.ofEpochSecond(1_000), isAlive = false),
            agentInfo(AGENT_2, path = "/srv/otro"),
            agentInfo(AGENT_3, createdAt = Instant.ofEpochSecond(2_000)),
        )
        val vm = loaded()
        assertEquals(AgentListLoad.Loaded, vm.state.value.load)
        assertEquals(listOf(AGENT_3, AGENT_1), vm.state.value.agents.map { it.id })
        assertEquals(listOf(true, false), vm.state.value.agents.map { it.isAlive })
    }

    @Test
    fun `una carpeta que solo empieza igual no cuenta como el proyecto`() = runTest(main.dispatcher) {
        ssh.agents = listOf(agentInfo(AGENT_1, path = "/srv/api2"), agentInfo(AGENT_2, path = "/srv/api/sub"))
        assertTrue(loaded().state.value.agents.isEmpty())
    }

    @Test
    fun `sin poder leer la lista se ve el error y se puede reintentar`() = runTest(main.dispatcher) {
        ssh.listError = networkDown()
        val vm = loaded()
        assertEquals(AgentListLoad.Failed(UiText.Plain("Sin red")), vm.state.value.load)

        ssh.listError = null
        ssh.agents = listOf(agentInfo())
        vm.refresh()
        assertEquals(AgentListLoad.Loading, vm.state.value.load)
        advanceUntilIdle()
        assertEquals(AgentListLoad.Loaded, vm.state.value.load)
        assertEquals(1, vm.state.value.agents.size)
    }

    @Test
    fun `tirar para recargar con la lista visible no la oculta si falla`() = runTest(main.dispatcher) {
        ssh.agents = listOf(agentInfo())
        val vm = loaded()

        ssh.listError = networkDown()
        vm.refresh()
        assertTrue(vm.state.value.isRefreshing)
        assertEquals(AgentListLoad.Loaded, vm.state.value.load)
        advanceUntilIdle()

        assertFalse(vm.state.value.isRefreshing)
        assertEquals(1, vm.state.value.agents.size)
        assertEquals(UiText.Plain("Sin red"), vm.state.value.message)
        vm.messageShown()
        assertNull(vm.state.value.message)
    }

    @Test
    fun `un servidor borrado se dice sin intentar conectar`() = runTest(main.dispatcher) {
        val vm = viewModel("no-existe")
        advanceUntilIdle()
        assertEquals(AgentListLoad.Failed(UiText.res(R.string.terminal_server_missing)), vm.state.value.load)
    }

    @Test
    fun `informa de si claude está, con qué sesión y si hay token`() = runTest(main.dispatcher) {
        tokens.token = SECRET_TOKEN
        val vm = loaded()
        assertEquals(ClaudeAvailability.SignedIn("max", "yo@example.com"), vm.state.value.claude)
        assertTrue(vm.state.value.hasSavedToken)

        ssh.authStatus = signedOut
        vm.refresh()
        advanceUntilIdle()
        assertEquals(ClaudeAvailability.SignedOut, vm.state.value.claude)

        ssh.authStatus = null
        vm.refresh()
        advanceUntilIdle()
        assertEquals(ClaudeAvailability.Missing, vm.state.value.claude)
    }

    @Test
    fun `no poder comprobar la sesión no oculta la lista`() = runTest(main.dispatcher) {
        ssh.agents = listOf(agentInfo())
        ssh.authError = networkDown()
        val vm = loaded()
        assertEquals(AgentListLoad.Loaded, vm.state.value.load)
        assertEquals(1, vm.state.value.agents.size)
        assertEquals(ClaudeAvailability.Unknown, vm.state.value.claude)
    }

    @Test
    fun `sin sesión en el servidor pero con token crea el agente pasándolo solo por stdin`() = runTest(main.dispatcher) {
        ssh.authStatus = signedOut
        tokens.token = SECRET_TOKEN
        val vm = loaded()
        val events = eventsOf(vm)

        vm.createAgent()
        assertTrue(vm.state.value.isCreating)
        advanceUntilIdle()

        val launch = ssh.launches.single()
        assertEquals("$SECRET_TOKEN\n", launch.stdinFirstChunk)
        assertFalse(SECRET_TOKEN in launch.command, "El token no va en la línea de comandos")
        assertTrue("/srv/api" in launch.command)
        assertFalse(vm.state.value.isCreating)
        assertIs<AgentListEvent.OpenAgent>(events.single())
    }

    @Test
    fun `con sesión en el servidor y sin token lanza con stdin vacío`() = runTest(main.dispatcher) {
        val vm = loaded()
        val events = eventsOf(vm)
        vm.createAgent()
        advanceUntilIdle()
        assertEquals("\n", ssh.launches.single().stdinFirstChunk)
        assertIs<AgentListEvent.OpenAgent>(events.single())
    }

    /** El `meta.json` que escribe el comando del lanzador. */
    private fun launchedMeta(command: String): PersistentAgentMeta {
        val base64 = Regex("printf '%s' '([A-Za-z0-9+/=]+)' \\| base64 -d > meta.json").find(command)?.groupValues?.get(1)
        return assertNotNull(PersistentAgentMeta.decode(String(Base64.getDecoder().decode(assertNotNull(base64)))))
    }

    private fun TestScope.launchedWith(vm: AgentListViewModel): String {
        vm.createAgent()
        advanceUntilIdle()
        return ssh.launches.last().command
    }

    @Test
    fun `sin nada configurado un agente nuevo arranca con todos los permisos`() = runTest(main.dispatcher) {
        val command = launchedWith(loaded())
        assertEquals(PermissionMode.BYPASS_PERMISSIONS, launchedMeta(command).resolvedPermissionMode)
        assertTrue("--permission-mode" in command && PermissionMode.BYPASS_PERMISSIONS.rawValue in command)
        // Con root, el CLI lo rechazaría: el comando pasa a preguntar.
        assertTrue("id -u" in command)
    }

    @Test
    fun `el ajuste global decide el modo del agente nuevo`() = runTest(main.dispatcher) {
        permissions.setGlobalMode(PermissionMode.PLAN)
        val command = launchedWith(loaded())
        assertEquals(PermissionMode.PLAN, launchedMeta(command).resolvedPermissionMode)
        assertTrue("--permission-mode plan" in command)
    }

    @Test
    fun `lo elegido en el proyecto manda sobre el ajuste global`() = runTest(main.dispatcher) {
        permissions.setGlobalMode(PermissionMode.BYPASS_PERMISSIONS)
        val vm = loaded()
        vm.setPermissionChoice(PermissionMode.DEFAULT)
        val command = launchedWith(vm)
        assertEquals(PermissionMode.DEFAULT, launchedMeta(command).resolvedPermissionMode)
        assertFalse(PermissionMode.BYPASS_PERMISSIONS.rawValue in command)
    }

    @Test
    fun `volver al ajuste global deja de usar el modo del proyecto`() = runTest(main.dispatcher) {
        permissions.setGlobalMode(PermissionMode.ACCEPT_EDITS)
        val vm = loaded()
        vm.setPermissionChoice(PermissionMode.PLAN)
        vm.setPermissionChoice(null)
        assertEquals(PermissionMode.ACCEPT_EDITS, launchedMeta(launchedWith(vm)).resolvedPermissionMode)
    }

    @Test
    fun `el selector refleja la elección, el ajuste global y el modo efectivo`() = runTest(main.dispatcher) {
        val vm = loaded()
        assertEquals(AgentPermissionSelection(null, PermissionMode.BYPASS_PERMISSIONS), vm.state.value.permissions)

        vm.showPermissionsDialog()
        assertEquals(AgentListDialog.Permissions, vm.state.value.dialog)

        vm.setPermissionChoice(PermissionMode.PLAN)
        advanceUntilIdle()
        assertEquals(PermissionMode.PLAN, vm.state.value.permissions.choice)
        assertEquals(PermissionMode.PLAN, vm.state.value.permissions.effective)

        vm.dismissDialog()
        assertNull(vm.state.value.dialog)
    }

    @Test
    fun `un cambio del ajuste global llega a la pantalla abierta`() = runTest(main.dispatcher) {
        val vm = loaded()
        permissions.setGlobalMode(PermissionMode.DEFAULT)
        advanceUntilIdle()
        assertEquals(PermissionMode.DEFAULT, vm.state.value.permissions.effective)
    }

    @Test
    fun `cada fila muestra el modo con el que se creó, no el ajuste actual`() = runTest(main.dispatcher) {
        permissions.setGlobalMode(PermissionMode.PLAN)
        ssh.agents = listOf(
            agentInfo(AGENT_1, permissionMode = "bypassPermissions", createdAt = Instant.ofEpochSecond(3_000)),
            agentInfo(AGENT_2, permissionMode = "modo-futuro", createdAt = Instant.ofEpochSecond(2_000)),
            agentInfo(AGENT_3, createdAt = Instant.ofEpochSecond(1_000)),
        )
        // Sin modo o con uno desconocido se crearon preguntando: nunca se muestra más permisivo.
        assertEquals(
            listOf(PermissionMode.BYPASS_PERMISSIONS, PermissionMode.DEFAULT, PermissionMode.DEFAULT),
            loaded().state.value.agents.map { it.permissionMode },
        )
    }

    @Test
    fun `reanudar conserva el modo del agente aunque el ajuste haya cambiado`() = runTest(main.dispatcher) {
        ssh.agents = listOf(agentInfo(isAlive = false, permissionMode = "plan"))
        permissions.setGlobalMode(PermissionMode.BYPASS_PERMISSIONS)
        val vm = loaded()
        vm.resume(AGENT_1)
        advanceUntilIdle()
        val command = ssh.launches.single().command
        assertEquals(PermissionMode.PLAN, launchedMeta(command).resolvedPermissionMode)
        assertTrue("--permission-mode plan" in command)
        assertFalse(PermissionMode.BYPASS_PERMISSIONS.rawValue in command)
    }

    @Test
    fun `reanudar un agente antiguo sin modo nunca sube sus permisos`() = runTest(main.dispatcher) {
        ssh.agents = listOf(agentInfo(isAlive = false))
        val vm = loaded()
        vm.resume(AGENT_1)
        advanceUntilIdle()
        val command = ssh.launches.single().command
        assertTrue("--permission-mode default" in command)
        assertFalse(PermissionMode.BYPASS_PERMISSIONS.rawValue in command)
    }

    @Test
    fun `comprueba la sesión antes de crear y sin ella ni token ofrece autenticarse`() = runTest(main.dispatcher) {
        val vm = loaded()
        ssh.authStatus = signedOut
        val checks = ssh.authCalls

        vm.createAgent()
        advanceUntilIdle()

        assertEquals(checks + 1, ssh.authCalls)
        assertEquals(AgentListDialog.AuthRequired, vm.state.value.dialog)
        assertTrue(ssh.launches.isEmpty())
        assertFalse(vm.state.value.isCreating)
    }

    @Test
    fun `claude sin instalar no lanza nada y lo dice`() = runTest(main.dispatcher) {
        val vm = loaded()
        ssh.authStatus = null
        vm.createAgent()
        advanceUntilIdle()
        assertEquals(ClaudeAvailability.Missing, vm.state.value.claude)
        assertNull(vm.state.value.dialog)
        assertTrue(ssh.launches.isEmpty())
    }

    @Test
    fun `una conexión sin canal exec da un error claro`() = runTest(main.dispatcher) {
        provider.service = FakeSSHService().apply { }.let { base ->
            object : com.iaportafolio.argos.core.SSHServicing by base {
                override suspend fun runAgentScript(command: String): String = ""
            }
        }
        val vm = loaded()
        assertEquals(AgentListLoad.Loaded, vm.state.value.load)
        vm.createAgent()
        advanceUntilIdle()
        assertEquals(R.string.agents_unsupported, messageRes(vm))
    }

    @Test
    fun `pegar un token tras el aviso guarda y continúa la creación`() = runTest(main.dispatcher) {
        ssh.authStatus = signedOut
        val vm = loaded()
        val events = eventsOf(vm)
        vm.createAgent()
        advanceUntilIdle()
        vm.showTokenDialog()
        assertEquals(AgentListDialog.Token, vm.state.value.dialog)

        vm.saveToken("  $SECRET_TOKEN\n")
        advanceUntilIdle()

        assertEquals(SECRET_TOKEN, tokens.token)
        assertTrue(vm.state.value.hasSavedToken)
        assertNull(vm.state.value.dialog)
        assertEquals("$SECRET_TOKEN\n", ssh.launches.single().stdinFirstChunk)
        assertIs<AgentListEvent.OpenAgent>(events.single())
    }

    @Test
    fun `guardar un token desde el menú no crea ningún agente`() = runTest(main.dispatcher) {
        val vm = loaded()
        vm.showTokenDialog()
        vm.saveToken(SECRET_TOKEN)
        advanceUntilIdle()
        assertEquals(SECRET_TOKEN, tokens.token)
        assertTrue(ssh.launches.isEmpty())
    }

    @Test
    fun `un token no válido no se guarda y se avisa en el diálogo`() = runTest(main.dispatcher) {
        val vm = loaded()
        vm.showTokenDialog()
        vm.saveToken("dos palabras")
        advanceUntilIdle()
        assertNull(tokens.token)
        assertEquals(UiText.res(R.string.agents_token_invalid), vm.state.value.tokenError)
        assertEquals(AgentListDialog.Token, vm.state.value.dialog)
    }

    @Test
    fun `un fallo al guardar el token no lo enseña`() = runTest(main.dispatcher) {
        tokens.saveError = IllegalStateException("cifrando $SECRET_TOKEN")
        val vm = loaded()
        vm.showTokenDialog()
        vm.saveToken(SECRET_TOKEN)
        advanceUntilIdle()
        assertEquals(UiText.res(R.string.agents_token_save_failed), vm.state.value.tokenError)
        assertFalse(SECRET_TOKEN in vm.state.value.toString())
    }

    @Test
    fun `se puede borrar el token`() = runTest(main.dispatcher) {
        tokens.token = SECRET_TOKEN
        val vm = loaded()
        vm.deleteToken()
        advanceUntilIdle()
        assertNull(tokens.token)
        assertFalse(vm.state.value.hasSavedToken)
        assertEquals(UiText.res(R.string.agents_token_deleted), vm.state.value.message)
    }

    @Test
    fun `iniciar sesión abre el login y al volver con sesión continúa la creación`() = runTest(main.dispatcher) {
        ssh.authStatus = signedOut
        val vm = loaded()
        val events = eventsOf(vm)
        vm.createAgent()
        advanceUntilIdle()

        vm.startLogin()
        advanceUntilIdle()
        assertEquals(listOf<AgentListEvent>(AgentListEvent.OpenLogin), events.toList())
        assertNull(vm.state.value.dialog)

        ssh.authStatus = ClaudeAuthStatus(loggedIn = true, subscriptionType = "pro", email = null)
        vm.refresh()
        advanceUntilIdle()
        assertEquals("\n", ssh.launches.single().stdinFirstChunk)
        assertIs<AgentListEvent.OpenAgent>(events.last())
    }

    @Test
    fun `recargar con el aviso abierto no pierde la creación pendiente`() = runTest(main.dispatcher) {
        ssh.authStatus = signedOut
        val vm = loaded()
        vm.createAgent()
        advanceUntilIdle()

        vm.refresh()
        advanceUntilIdle()
        assertEquals(AgentListDialog.AuthRequired, vm.state.value.dialog)

        vm.showTokenDialog()
        vm.saveToken(SECRET_TOKEN)
        advanceUntilIdle()
        assertEquals("$SECRET_TOKEN\n", ssh.launches.single().stdinFirstChunk)
    }

    @Test
    fun `volver del login sin sesión no insiste`() = runTest(main.dispatcher) {
        ssh.authStatus = signedOut
        val vm = loaded()
        vm.createAgent()
        advanceUntilIdle()
        vm.startLogin()
        advanceUntilIdle()

        vm.refresh()
        advanceUntilIdle()
        assertNull(vm.state.value.dialog)
        assertTrue(ssh.launches.isEmpty())
    }

    @Test
    fun `cerrar el aviso abandona la creación pendiente`() = runTest(main.dispatcher) {
        ssh.authStatus = signedOut
        val vm = loaded()
        vm.createAgent()
        advanceUntilIdle()
        vm.dismissDialog()

        ssh.authStatus = ClaudeAuthStatus(loggedIn = true, subscriptionType = null, email = null)
        vm.refresh()
        advanceUntilIdle()
        assertTrue(ssh.launches.isEmpty())
    }

    @Test
    fun `un token ilegible no impide lanzar si el servidor tiene sesión`() = runTest(main.dispatcher) {
        tokens.token = SECRET_TOKEN
        tokens.readError = ClaudeTokenUnavailableException()
        val vm = loaded()
        vm.createAgent()
        advanceUntilIdle()
        assertEquals("\n", ssh.launches.single().stdinFirstChunk)
    }

    @Test
    fun `un token ilegible sin sesión en el servidor se dice`() = runTest(main.dispatcher) {
        ssh.authStatus = signedOut
        tokens.token = SECRET_TOKEN
        tokens.readError = ClaudeTokenUnavailableException()
        val vm = loaded()
        vm.createAgent()
        advanceUntilIdle()
        assertEquals(R.string.agents_token_unreadable, messageRes(vm))
        assertTrue(ssh.launches.isEmpty())
    }

    @Test
    fun `si otro dispositivo está arrancando se avisa`() = runTest(main.dispatcher) {
        ssh.launchReply = "ARGOS_AGENT_BUSY\n"
        val vm = loaded()
        vm.createAgent()
        advanceUntilIdle()
        assertTrue((vm.state.value.message as UiText.Plain).value.startsWith("Otro dispositivo"))
        assertFalse(vm.state.value.isCreating)
    }

    @Test
    fun `parar un agente lo marca detenido al recargar`() = runTest(main.dispatcher) {
        ssh.agents = listOf(agentInfo())
        val vm = loaded()
        vm.stop(AGENT_1)
        assertTrue(vm.state.value.agents.single().isBusy)
        advanceUntilIdle()
        assertEquals(PersistentAgentScript.stop(AGENT_1, delete = false), ssh.scripts.single())
        assertFalse(vm.state.value.agents.single().isAlive)
        assertFalse(vm.state.value.agents.single().isBusy)
    }

    @Test
    fun `un fallo al parar se ve y el agente sigue en la lista`() = runTest(main.dispatcher) {
        ssh.agents = listOf(agentInfo())
        val vm = loaded()
        ssh.scriptError = networkDown()
        vm.stop(AGENT_1)
        advanceUntilIdle()
        assertEquals(UiText.Plain("Sin red"), vm.state.value.message)
        assertTrue(vm.state.value.agents.single().isAlive)
    }

    @Test
    fun `reanudar pasa el token por stdin sin dejar enganche abierto`() = runTest(main.dispatcher) {
        tokens.token = SECRET_TOKEN
        ssh.agents = listOf(agentInfo(isAlive = false))
        val vm = loaded()
        vm.resume(AGENT_1)
        advanceUntilIdle()
        val launch = ssh.launches.single()
        assertEquals("$SECRET_TOKEN\n", launch.stdinFirstChunk)
        assertTrue("--resume" in launch.command)
        assertFalse(SECRET_TOKEN in launch.command)
        assertTrue(ssh.attaches.all { it.closed })
    }

    @Test
    fun `un fallo al reanudar se ve, sin el token`() = runTest(main.dispatcher) {
        tokens.token = SECRET_TOKEN
        ssh.agents = listOf(agentInfo(isAlive = false))
        ssh.launchError = AgentExecException("error con $SECRET_TOKEN")
        val vm = loaded()
        vm.resume(AGENT_1)
        advanceUntilIdle()
        val message = (vm.state.value.message as UiText.Plain).value
        assertTrue("error con" in message)
        assertFalse(SECRET_TOKEN in message)
    }

    @Test
    fun `borrar pide confirmación y hasta entonces no toca el servidor`() = runTest(main.dispatcher) {
        ssh.agents = listOf(agentInfo())
        val vm = loaded()

        vm.requestDelete(AGENT_1)
        advanceUntilIdle()
        assertEquals(AgentListDialog.ConfirmDelete(AGENT_1, "api"), vm.state.value.dialog)
        assertTrue(ssh.scripts.isEmpty())

        vm.dismissDialog()
        advanceUntilIdle()
        assertTrue(ssh.scripts.isEmpty())
        assertEquals(1, vm.state.value.agents.size)

        vm.requestDelete(AGENT_1)
        vm.confirmDelete()
        advanceUntilIdle()
        assertEquals(PersistentAgentScript.stop(AGENT_1, delete = true), ssh.scripts.single())
        assertTrue(vm.state.value.agents.isEmpty())
    }

    @Test
    fun `si no se puede borrar la fila sigue y se avisa`() = runTest(main.dispatcher) {
        ssh.agents = listOf(agentInfo())
        val vm = loaded()
        ssh.scriptError = networkDown()
        vm.requestDelete(AGENT_1)
        vm.confirmDelete()
        advanceUntilIdle()
        assertEquals(1, vm.state.value.agents.size)
        assertEquals(UiText.Plain("Sin red"), vm.state.value.message)
    }

    @Test
    fun `abrir un agente emite el evento`() = runTest(main.dispatcher) {
        ssh.agents = listOf(agentInfo())
        val vm = loaded()
        val events = eventsOf(vm)
        vm.openAgent(AGENT_1)
        advanceUntilIdle()
        assertEquals(listOf<AgentListEvent>(AgentListEvent.OpenAgent(AGENT_1)), events.toList())
    }

    @Test
    fun `el token no aparece nunca en el estado ni en los errores`() = runTest(main.dispatcher) {
        ssh.authStatus = signedOut
        tokens.token = SECRET_TOKEN
        ssh.agents = listOf(agentInfo(isAlive = false))
        val seen = mutableListOf<String>()
        val vm = viewModel()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { vm.state.collect { seen += it.toString() } }
        advanceUntilIdle()

        ssh.launchError = AgentExecException("stderr: export CLAUDE_CODE_OAUTH_TOKEN=$SECRET_TOKEN")
        vm.createAgent()
        advanceUntilIdle()
        vm.messageShown()
        vm.resume(AGENT_1)
        advanceUntilIdle()
        vm.showTokenDialog()
        vm.saveToken(SECRET_TOKEN)
        advanceUntilIdle()
        vm.deleteToken()
        advanceUntilIdle()

        assertTrue(seen.isNotEmpty())
        seen.forEach { assertFalse(SECRET_TOKEN in it, it) }
    }
}
