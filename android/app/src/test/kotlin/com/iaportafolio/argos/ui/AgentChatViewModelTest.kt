@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.viewmodel.CreationExtras
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.agent.AgentExecException
import com.iaportafolio.argos.core.agent.AgentPermissionDecision
import com.iaportafolio.argos.core.agent.AgentProtocol
import com.iaportafolio.argos.core.agent.ClaudeAgentCommand
import com.iaportafolio.argos.core.agent.PersistentAgentError
import com.iaportafolio.argos.core.agent.PersistentAgentException
import com.iaportafolio.argos.core.agent.PersistentAgentScript
import com.iaportafolio.argos.data.ClaudeTokenUnavailableException
import com.iaportafolio.argos.testing.AGENT_1
import com.iaportafolio.argos.testing.AgentLog
import com.iaportafolio.argos.testing.FakeAgentService
import com.iaportafolio.argos.testing.FakeSSHService
import com.iaportafolio.argos.testing.InMemoryClaudeTokens
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.MainDispatcherExtension
import com.iaportafolio.argos.testing.RecordingAttention
import com.iaportafolio.argos.testing.SECRET_TOKEN
import com.iaportafolio.argos.testing.SingleServiceProvider
import com.iaportafolio.argos.testing.agentInfo
import com.iaportafolio.argos.testing.networkDown
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.ui.agents.AgentChatEvent
import com.iaportafolio.argos.ui.agents.AgentChatLoad
import com.iaportafolio.argos.ui.agents.AgentChatPolicy
import com.iaportafolio.argos.ui.agents.AgentChatStatus
import com.iaportafolio.argos.ui.agents.AgentChatViewModel
import com.iaportafolio.argos.ui.agents.AgentConnection
import com.iaportafolio.argos.ui.agents.AgentTranscriptRow
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.terminal.ReconnectPolicy
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.RegisterExtension
import kotlin.reflect.KClass
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AgentChatViewModelTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val repository = InMemoryServerRepository(listOf(server()))
    private val ssh = FakeAgentService().apply { agents = listOf(agentInfo()) }
    private val provider = SingleServiceProvider(ssh)
    private val tokens = InMemoryClaudeTokens()
    private val attention = RecordingAttention()
    private val policy = AgentChatPolicy(
        reconnect = ReconnectPolicy(delaysMillis = listOf(1_000, 2_000), maxAttempts = 2),
        livenessIntervalMillis = 60_000,
        replayTimeoutMillis = 30_000,
    )
    private val store = ViewModelStore()

    private fun viewModel(): AgentChatViewModel {
        val factory = object : ViewModelProvider.Factory {
            override fun <T : ViewModel> create(modelClass: KClass<T>, extras: CreationExtras): T {
                @Suppress("UNCHECKED_CAST")
                return AgentChatViewModel("S1", AGENT_1, repository, provider, tokens, main.dispatcher, policy, attention) as T
            }
        }
        return ViewModelProvider.create(store, factory)[AgentChatViewModel::class]
    }

    /** Los bucles del chat no terminan solos: el ViewModel se destruye siempre al final. */
    private fun chatTest(body: suspend TestScope.() -> Unit) = runTest(main.dispatcher) {
        try {
            body()
        } finally {
            store.clear()
        }
    }

    /** VM enganchado (ON_START) y con el enganche ya abierto. */
    private fun TestScope.attached(): AgentChatViewModel = viewModel().also {
        it.onStart()
        runCurrent()
    }

    private fun TestScope.eventsOf(vm: AgentChatViewModel): List<AgentChatEvent> {
        val events = mutableListOf<AgentChatEvent>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { vm.events.toList(events) }
        return events
    }

    private fun bytes(vararg lines: String): Long = lines.sumOf { "$it\n".toByteArray().size.toLong() }

    private val allowR1 get() = PersistentAgentScript.send(
        AGENT_1,
        AgentProtocol.encodePermissionResponse(
            "r1",
            AgentPermissionDecision.Allow(Json.parseToJsonElement("""{"command":"rm -rf build"}""")),
        ),
        "r1",
    )

    // MARK: - Carga

    @Test
    fun `abre el agente y pinta lo que llega del log`() = chatTest {
        val vm = attached()
        assertEquals(AgentChatLoad.Ready, vm.state.value.load)
        assertEquals("api", vm.state.value.title)
        assertEquals("/srv/api", vm.state.value.workingDirectory)
        assertEquals(PersistentAgentScript.attach(AGENT_1), ssh.attaches.single().command)

        ssh.attaches.single().emit(AgentLog.user("hola"), AgentLog.assistant("**sí**"), AgentLog.result())
        runCurrent()

        val rows = vm.state.value.rows
        assertIs<AgentTranscriptRow.User>(rows[0])
        assertEquals(AgentTranscriptRow.Assistant(1, "**sí**"), rows[1])
        assertIs<AgentTranscriptRow.TurnEnd>(rows[2])
        assertEquals(AgentConnection.Connected, vm.state.value.connection)
        assertEquals(AgentChatStatus.IDLE, vm.state.value.status)
    }

    @Test
    fun `el estado pasa a trabajando con el eco del usuario`() = chatTest {
        val vm = attached()
        ssh.attaches.single().emit(AgentLog.user("hola"))
        runCurrent()
        assertEquals(AgentChatStatus.WORKING, vm.state.value.status)
    }

    @Test
    fun `un agente que ya no está se dice`() = chatTest {
        ssh.agents = emptyList()
        val vm = attached()
        assertEquals(AgentChatLoad.Missing, vm.state.value.load)
        assertTrue(ssh.attaches.isEmpty())
    }

    @Test
    fun `si no se puede abrir se ve el error y reintentar lo abre`() = chatTest {
        ssh.listError = networkDown()
        val vm = attached()
        assertEquals(AgentChatLoad.Failed(UiText.Plain("Sin red")), vm.state.value.load)

        ssh.listError = null
        vm.reconnect()
        assertEquals(AgentChatLoad.Loading, vm.state.value.load)
        runCurrent()
        assertEquals(AgentChatLoad.Ready, vm.state.value.load)
        assertEquals(1, ssh.attaches.size)
    }

    @Test
    fun `una conexión sin canal exec da un error claro`() = chatTest {
        provider.service = FakeSSHService()
        val vm = attached()
        assertEquals(AgentChatLoad.Failed(UiText.res(R.string.agents_unsupported)), vm.state.value.load)
    }

    @Test
    fun `no poder leer el token no impide abrir la conversación`() = chatTest {
        tokens.token = SECRET_TOKEN
        tokens.readError = ClaudeTokenUnavailableException()
        val vm = attached()
        assertEquals(AgentChatLoad.Ready, vm.state.value.load)
    }

    // MARK: - Ciclo de vida

    @Test
    fun `al pasar a segundo plano se desengancha y al volver se engancha de nuevo`() = chatTest {
        val vm = attached()
        val first = ssh.attaches.single()

        vm.onStop()
        runCurrent()
        assertTrue(first.cancelled)
        assertTrue(first.closed)
        assertTrue(ssh.scripts.isEmpty(), "Desengancharse no para al agente")

        vm.onStart()
        runCurrent()
        assertEquals(2, ssh.attaches.size)
    }

    @Test
    fun `un segundo ON_START no abre otro enganche`() = chatTest {
        val vm = attached()
        vm.onStart()
        runCurrent()
        assertEquals(1, ssh.attaches.size)
    }

    @Test
    fun `salir de la pantalla cancela el enganche sin parar el agente`() = chatTest {
        attached()
        val call = ssh.attaches.single()
        store.clear()
        runCurrent()
        assertTrue(call.cancelled)
        assertTrue(ssh.scripts.isEmpty())
    }

    @Test
    fun `en segundo plano no se comprueba nada ni se reintenta`() = chatTest {
        val vm = attached()
        vm.onStop()
        runCurrent()
        val attaches = ssh.attaches.size
        advanceTimeBy(600_000)
        runCurrent()
        assertEquals(attaches, ssh.attaches.size)
    }

    // MARK: - Reenganche con backoff

    @Test
    fun `si el enganche cae reintenta con backoff y al agotarlos pide reconectar`() = chatTest {
        val vm = attached()

        ssh.attaches[0].end.complete(networkDown())
        runCurrent()
        assertEquals(AgentConnection.Retrying(1, 1), vm.state.value.connection)
        advanceTimeBy(999)
        runCurrent()
        assertEquals(1, ssh.attaches.size)
        advanceTimeBy(1)
        runCurrent()
        assertEquals(2, ssh.attaches.size)

        ssh.attaches[1].end.complete(networkDown())
        runCurrent()
        assertEquals(AgentConnection.Retrying(2, 2), vm.state.value.connection)
        advanceTimeBy(2_000)
        runCurrent()
        assertEquals(3, ssh.attaches.size)

        ssh.attaches[2].end.complete(networkDown())
        runCurrent()
        assertEquals(AgentConnection.Lost(UiText.Plain("Sin red")), vm.state.value.connection)
        advanceTimeBy(600_000)
        runCurrent()
        assertEquals(3, ssh.attaches.size)

        vm.reconnect()
        runCurrent()
        assertEquals(4, ssh.attaches.size)
    }

    @Test
    fun `si vuelve a llegar el log la cuenta de reintentos empieza de cero`() = chatTest {
        val vm = attached()
        ssh.attaches[0].end.complete(networkDown())
        runCurrent()
        advanceTimeBy(1_000)
        runCurrent()

        ssh.attaches[1].emit(AgentLog.assistant("hola"))
        runCurrent()
        assertEquals(AgentConnection.Connected, vm.state.value.connection)

        ssh.attaches[1].end.complete(networkDown())
        runCurrent()
        assertEquals(AgentConnection.Retrying(1, 1), vm.state.value.connection)
    }

    @Test
    fun `un fin limpio del enganche también reengancha`() = chatTest {
        attached()
        ssh.attaches[0].end.complete(null)
        runCurrent()
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals(2, ssh.attaches.size)
    }

    @Test
    fun `al reengancharse conserva la conversación mientras relee el log`() = chatTest {
        val lines = arrayOf(AgentLog.user("hola"), AgentLog.assistant("adiós"))
        val vm = attached()
        ssh.attaches[0].emit(*lines)
        runCurrent()
        val before = vm.state.value.rows

        vm.onStop()
        vm.onStart()
        runCurrent()
        assertTrue(vm.state.value.isReplaying)
        assertEquals(before, vm.state.value.rows)
        assertEquals(AgentChatStatus.CONNECTING, vm.state.value.status)

        ssh.attaches[1].emit(lines[0])
        runCurrent()
        assertEquals(before, vm.state.value.rows)

        ssh.attaches[1].emit(lines[1])
        runCurrent()
        assertFalse(vm.state.value.isReplaying)
        assertEquals(before, vm.state.value.rows)
    }

    @Test
    fun `una petición ya respondida no reaparece al releer el log`() = chatTest {
        val request = AgentLog.permission("r1")
        val answer = AgentLog.answered("r1")
        ssh.agents = listOf(agentInfo(logBytes = bytes(request, answer)))
        val vm = attached()

        ssh.attaches[0].emit(request)
        runCurrent()
        assertNull(vm.state.value.visiblePermission, "Aún no se ha releído su respuesta")

        ssh.attaches[0].emit(answer)
        runCurrent()
        assertNull(vm.state.value.visiblePermission)
        assertFalse(vm.state.value.isReplaying)
    }

    @Test
    fun `si el log es más corto de lo esperado no se queda reteniendo para siempre`() = chatTest {
        ssh.agents = listOf(agentInfo(logBytes = 1_000_000))
        val vm = attached()
        ssh.attaches[0].emit(AgentLog.assistant("hola"))
        runCurrent()
        assertTrue(vm.state.value.isReplaying)

        advanceTimeBy(policy.replayTimeoutMillis)
        runCurrent()
        assertFalse(vm.state.value.isReplaying)
        assertEquals(1, vm.state.value.rows.size)
    }

    // MARK: - Enviar

    @Test
    fun `enviar llega a la FIFO y vacía la caja cuando se confirma`() = chatTest {
        val vm = attached()
        val events = eventsOf(vm)

        vm.send("  ¿qué tal? ñandú 😀\n")
        assertTrue(vm.state.value.isSending)
        assertFalse(vm.state.value.canSend)
        runCurrent()

        assertEquals(PersistentAgentScript.send(AGENT_1, AgentProtocol.encodeUserMessage("¿qué tal? ñandú 😀")), ssh.scripts.single())
        assertEquals(listOf<AgentChatEvent>(AgentChatEvent.MessageSent), events.toList())
        assertFalse(vm.state.value.isSending)
    }

    @Test
    fun `un mensaje en blanco no se envía`() = chatTest {
        val vm = attached()
        vm.send("   \n ")
        runCurrent()
        assertTrue(ssh.scripts.isEmpty())
    }

    @Test
    fun `si no llega se ve el error y se conserva lo escrito`() = chatTest {
        val vm = attached()
        val events = eventsOf(vm)
        ssh.scriptError = networkDown()
        vm.send("hola")
        runCurrent()
        assertEquals(UiText.Plain("Sin red"), vm.state.value.error)
        assertEquals(AgentChatStatus.ERROR, vm.state.value.status)
        assertTrue(events.isEmpty())
        vm.errorDismissed()
        assertNull(vm.state.value.error)
    }

    // MARK: - Permisos

    private suspend fun TestScope.withPendingPermission(): AgentChatViewModel {
        val vm = attached()
        ssh.attaches.last().emit(AgentLog.permission("r1"))
        runCurrent()
        return vm
    }

    @Test
    fun `muestra qué herramienta pide permiso y con qué`() = chatTest {
        val vm = withPendingPermission()
        val card = assertNotNull(vm.state.value.visiblePermission)
        assertEquals("r1", card.requestId)
        assertEquals("Bash", card.tool)
        assertEquals("rm -rf build", card.summary)
        assertEquals(AgentChatStatus.AWAITING_PERMISSION, vm.state.value.status)
    }

    @Test
    fun `permitir responde con el input y marca la petición en el log`() = chatTest {
        val vm = withPendingPermission()
        vm.decidePermission("r1", allow = true)
        assertFalse(vm.state.value.canDecidePermission)
        runCurrent()
        assertEquals(allowR1, ssh.scripts.single())
        assertNull(vm.state.value.visiblePermission)
        assertTrue(vm.state.value.canDecidePermission)
    }

    @Test
    fun `denegar responde con el mensaje de denegación`() = chatTest {
        val vm = withPendingPermission()
        vm.decidePermission("r1", allow = false)
        runCurrent()
        val expected = PersistentAgentScript.send(
            AGENT_1,
            AgentProtocol.encodePermissionResponse("r1", AgentPermissionDecision.Deny(AgentPermissionDecision.USER_DENIED_MESSAGE)),
            "r1",
        )
        assertEquals(expected, ssh.scripts.single())
        assertNull(vm.state.value.visiblePermission)
    }

    @Test
    fun `nunca se aprueba una petición distinta de la que se ve`() = chatTest {
        val vm = withPendingPermission()
        ssh.attaches.last().emit(AgentLog.permission("r2", inputJson = """{"command":"rm -rf /"}"""))
        runCurrent()

        vm.decidePermission("r1", allow = true)
        runCurrent()
        assertTrue(ssh.scripts.isEmpty())
        assertEquals("r2", vm.state.value.visiblePermission?.requestId)
    }

    @Test
    fun `una doble pulsación solo responde una vez`() = chatTest {
        val vm = withPendingPermission()
        vm.decidePermission("r1", allow = true)
        vm.decidePermission("r1", allow = true)
        runCurrent()
        assertEquals(1, ssh.scripts.size)
    }

    @Test
    fun `si la respuesta no llega se avisa y la tarjeta sigue para reintentar`() = chatTest {
        val vm = withPendingPermission()
        ssh.scriptError = networkDown()
        vm.decidePermission("r1", allow = true)
        runCurrent()
        assertEquals(UiText.Plain("Sin red"), vm.state.value.error)
        assertEquals("r1", vm.state.value.visiblePermission?.requestId)
        assertEquals(1, ssh.attaches.size)

        ssh.scriptError = null
        vm.decidePermission("r1", allow = true)
        runCurrent()
        assertEquals(allowR1, ssh.scripts.last())
        assertNull(vm.state.value.visiblePermission)
        assertNull(vm.state.value.error)
    }

    @Test
    fun `sin enganche la tarjeta se ve pero no se puede decidir`() = chatTest {
        val vm = withPendingPermission()
        ssh.attaches.last().end.complete(networkDown())
        runCurrent()
        assertNotNull(vm.state.value.visiblePermission)
        assertFalse(vm.state.value.canDecidePermission)

        vm.decidePermission("r1", allow = true)
        runCurrent()
        assertTrue(ssh.scripts.isEmpty())
    }

    @Test
    fun `un permiso cancelado por el agente desaparece`() = chatTest {
        val vm = withPendingPermission()
        ssh.attaches.last().emit("""{"type":"control_cancel_request","request_id":"r1"}""")
        runCurrent()
        assertNull(vm.state.value.visiblePermission)
    }

    // MARK: - Agente muerto

    @Test
    fun `el sondeo detecta que el proceso murió aunque el log siga abierto`() = chatTest {
        val vm = attached()
        ssh.attaches.single().emit(AgentLog.user("hola"))
        runCurrent()
        assertEquals(AgentChatStatus.WORKING, vm.state.value.status)

        ssh.agents = listOf(agentInfo(isAlive = false))
        advanceTimeBy(policy.livenessIntervalMillis)
        runCurrent()

        assertFalse(vm.state.value.isAlive)
        assertEquals(AgentChatStatus.TERMINATED, vm.state.value.status)
        assertFalse(vm.state.value.canSend)
    }

    @Test
    fun `descubrirlo al enviar también lo marca muerto`() = chatTest {
        val vm = attached()
        ssh.scriptError = PersistentAgentException(PersistentAgentError.NOT_RUNNING)
        vm.send("hola")
        runCurrent()
        assertFalse(vm.state.value.isAlive)
        assertEquals(AgentChatStatus.TERMINATED, vm.state.value.status)
    }

    @Test
    fun `un agente muerto no ofrece responder a su petición`() = chatTest {
        val vm = withPendingPermission()
        ssh.agents = listOf(agentInfo(isAlive = false))
        advanceTimeBy(policy.livenessIntervalMillis)
        runCurrent()
        assertNull(vm.state.value.visiblePermission)
    }

    @Test
    fun `reanudar pasa el token por stdin y vuelve a engancharse`() = chatTest {
        tokens.token = SECRET_TOKEN
        ssh.agents = listOf(agentInfo(isAlive = false))
        val vm = attached()
        assertFalse(vm.state.value.isAlive)
        val attachesBefore = ssh.attaches.size

        ssh.agents = listOf(agentInfo(isAlive = true))
        vm.resume()
        assertTrue(vm.state.value.isResuming)
        runCurrent()

        val launch = ssh.launches.single()
        assertEquals("$SECRET_TOKEN\n", launch.stdinFirstChunk)
        assertTrue("--resume" in launch.command)
        assertFalse(SECRET_TOKEN in launch.command)
        assertTrue(vm.state.value.isAlive)
        assertFalse(vm.state.value.isResuming)
        assertTrue(ssh.attaches.size > attachesBefore)
        assertFalse(ssh.attaches.last().closed)
    }

    @Test
    fun `si no se puede reanudar se ve el error y sigue detenido`() = chatTest {
        ssh.agents = listOf(agentInfo(isAlive = false))
        val vm = attached()
        ssh.launchError = AgentExecException("sin permisos")
        vm.resume()
        runCurrent()
        assertFalse(vm.state.value.isAlive)
        assertTrue((vm.state.value.error as UiText.Plain).value.contains("sin permisos"))
    }

    @Test
    fun `un token ilegible al reanudar se dice sin lanzar nada`() = chatTest {
        ssh.agents = listOf(agentInfo(isAlive = false))
        val vm = attached()
        tokens.token = SECRET_TOKEN
        tokens.readError = ClaudeTokenUnavailableException()
        vm.resume()
        runCurrent()
        assertEquals(UiText.res(R.string.agents_token_unreadable), vm.state.value.error)
        assertTrue(ssh.launches.isEmpty())
    }

    @Test
    fun `si otro dispositivo borra el agente se deja de seguir`() = chatTest {
        val vm = attached()
        val call = ssh.attaches.single()
        ssh.agents = emptyList()
        advanceTimeBy(policy.livenessIntervalMillis)
        runCurrent()
        assertEquals(AgentChatLoad.Missing, vm.state.value.load)
        assertTrue(call.cancelled)

        vm.onStart()
        runCurrent()
        assertEquals(1, ssh.attaches.size)
    }

    // MARK: - Parar y borrar

    @Test
    fun `parar deja el agente detenido`() = chatTest {
        val vm = attached()
        vm.stop()
        runCurrent()
        assertEquals(PersistentAgentScript.stop(AGENT_1, delete = false), ssh.scripts.single())
        assertFalse(vm.state.value.isAlive)
        assertFalse(vm.state.value.isStopping)
    }

    @Test
    fun `si no se puede parar se ve el error y sigue en marcha`() = chatTest {
        val vm = attached()
        ssh.scriptError = networkDown()
        vm.stop()
        runCurrent()
        assertTrue(vm.state.value.isAlive)
        assertEquals(UiText.Plain("Sin red"), vm.state.value.error)
    }

    @Test
    fun `borrar pide confirmación y al confirmar cierra la conversación`() = chatTest {
        val vm = attached()
        val events = eventsOf(vm)

        vm.requestDelete()
        runCurrent()
        assertTrue(vm.state.value.confirmDelete)
        assertTrue(ssh.scripts.isEmpty())

        vm.cancelDelete()
        assertFalse(vm.state.value.confirmDelete)
        assertTrue(ssh.scripts.isEmpty())

        vm.requestDelete()
        vm.confirmDelete()
        runCurrent()
        assertEquals(PersistentAgentScript.stop(AGENT_1, delete = true), ssh.scripts.single())
        assertEquals(listOf<AgentChatEvent>(AgentChatEvent.Closed), events.toList())
        assertTrue(ssh.attaches.single().cancelled)
    }

    @Test
    fun `si no se puede borrar la conversación sigue abierta`() = chatTest {
        val vm = attached()
        val events = eventsOf(vm)
        ssh.scriptError = networkDown()
        vm.requestDelete()
        vm.confirmDelete()
        runCurrent()
        assertTrue(events.isEmpty())
        assertEquals(UiText.Plain("Sin red"), vm.state.value.error)
        assertFalse(ssh.attaches.single().closed)
    }

    // MARK: - Modo de permisos

    @Test
    fun `la cabecera sabe con qué modo corre el agente`() = chatTest {
        ssh.agents = listOf(agentInfo(permissionMode = "bypassPermissions"))
        val vm = viewModel()
        assertNull(vm.state.value.permissionMode)
        vm.onStart()
        runCurrent()
        assertEquals(ClaudeAgentCommand.PermissionMode.BYPASS_PERMISSIONS, vm.state.value.permissionMode)
    }

    @Test
    fun `un agente sin modo guardado consta como que pregunta`() = chatTest {
        assertEquals(ClaudeAgentCommand.PermissionMode.DEFAULT, attached().state.value.permissionMode)
    }

    @Test
    fun `reanudar desde el chat conserva el modo del meta`() = chatTest {
        ssh.agents = listOf(agentInfo(isAlive = false, permissionMode = "acceptEdits"))
        val vm = attached()
        vm.resume()
        assertEquals(ClaudeAgentCommand.PermissionMode.ACCEPT_EDITS, vm.state.value.confirmResumeMode)
        vm.confirmResume()
        runCurrent()
        val command = ssh.launches.single().command
        assertTrue("--permission-mode acceptEdits" in command)
        assertFalse(ClaudeAgentCommand.PermissionMode.BYPASS_PERMISSIONS.rawValue in command)
        assertEquals(ClaudeAgentCommand.PermissionMode.ACCEPT_EDITS, vm.state.value.permissionMode)
    }

    @Test
    fun `reanudar con todos los permisos segun el meta exige confirmar`() = chatTest {
        ssh.agents = listOf(agentInfo(isAlive = false, permissionMode = "bypassPermissions"))
        val vm = attached()
        vm.resume()
        runCurrent()
        assertEquals(ClaudeAgentCommand.PermissionMode.BYPASS_PERMISSIONS, vm.state.value.confirmResumeMode)
        assertTrue(ssh.launches.isEmpty(), "No debe relanzar sin confirmación")

        vm.cancelResume()
        runCurrent()
        assertEquals(null, vm.state.value.confirmResumeMode)
        assertTrue(ssh.launches.isEmpty())

        vm.confirmResume()
        runCurrent()
        assertTrue(ssh.launches.isEmpty(), "Confirmar sin haberlo pedido no relanza")

        vm.resume()
        vm.confirmResume()
        runCurrent()
        assertEquals(null, vm.state.value.confirmResumeMode)
        assertEquals(1, ssh.launches.size)
    }

    // MARK: - Secretos

    @Test
    fun `el token no aparece nunca en el estado ni en los errores`() = chatTest {
        tokens.token = SECRET_TOKEN
        val seen = mutableListOf<String>()
        val vm = viewModel()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { vm.state.collect { seen += it.toString() } }
        vm.onStart()
        runCurrent()

        ssh.attaches.last().emit(
            AgentLog.user("mi token es $SECRET_TOKEN"),
            AgentLog.assistant("env dice $SECRET_TOKEN"),
            AgentLog.toolUse("Bash", """{"command":"echo $SECRET_TOKEN"}"""),
            AgentLog.permission("r1", inputJson = """{"command":"curl -H $SECRET_TOKEN"}"""),
        )
        runCurrent()
        ssh.scriptError = AgentExecException("stderr $SECRET_TOKEN")
        vm.send("hola")
        runCurrent()
        vm.decidePermission("r1", allow = false)
        runCurrent()
        vm.stop()
        runCurrent()
        ssh.attaches.last().end.complete(AgentExecException("caída $SECRET_TOKEN"))
        runCurrent()
        ssh.launchError = AgentExecException("lanzador $SECRET_TOKEN")
        vm.resume()
        runCurrent()

        assertTrue(seen.size > 3)
        seen.forEach { assertFalse(SECRET_TOKEN in it, it) }
        assertNotNull(vm.state.value.error)
    }

    // MARK: - Avisos

    @Test
    fun `abrir un agente apunta el servidor y lo marca a la vista`() = chatTest {
        attached()
        assertEquals(listOf("S1"), attention.opened)
        assertEquals(listOf("S1" to AGENT_1), attention.shown)
    }

    @Test
    fun `un agente que no existe no apunta el servidor`() = chatTest {
        ssh.agents = emptyList()
        attached()
        assertTrue(attention.opened.isEmpty())
    }

    @Test
    fun `al pasar a segundo plano guarda lo recibido como visto`() = chatTest {
        val vm = attached()
        ssh.attaches.single().emit(AgentLog.result())
        runCurrent()

        vm.onStop()

        assertEquals(listOf(Triple("S1", AGENT_1, bytes(AgentLog.result()))), attention.hidden)
    }
}
