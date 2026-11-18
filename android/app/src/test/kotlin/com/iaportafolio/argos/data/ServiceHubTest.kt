package com.iaportafolio.argos.data

import com.iaportafolio.argos.core.AuthMethod
import com.iaportafolio.argos.core.HostKeyTrustStore
import com.iaportafolio.argos.core.SSHConnector
import com.iaportafolio.argos.core.SSHCredentials
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.testing.FakeSSHService
import com.iaportafolio.argos.testing.InMemorySecretStore
import com.iaportafolio.argos.testing.InMemoryTrustStore
import com.iaportafolio.argos.testing.server
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNotSame
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class ServiceHubTest {

    private val secrets = InMemorySecretStore()
    private val trust = InMemoryTrustStore()

    private class RecordingConnector : SSHConnector {
        val made = mutableListOf<Triple<Server, SSHCredentials, FakeSSHService>>()
        var trustSeen: HostKeyTrustStore? = null

        override fun service(server: Server, credentials: SSHCredentials, trust: HostKeyTrustStore): FakeSSHService {
            trustSeen = trust
            return FakeSSHService().also { made += Triple(server, credentials, it) }
        }
    }

    private val connector = RecordingConnector()

    private fun TestScope.hub() = ServiceHub(connector, secrets, trust, StandardTestDispatcher(testScheduler))

    @Test
    fun `contraseña del almacén y el TrustStore llegan al conector`() = runTest {
        secrets.write("S1", SecretKind.PASSWORD, "pw")
        hub().service(server())

        val credentials = assertIs<SSHCredentials.Password>(connector.made.single().second)
        assertEquals("pw", credentials.password)
        assertSame(trust, connector.trustSeen)
    }

    @Test
    fun `clave con y sin passphrase`() = runTest {
        secrets.write("K", SecretKind.PRIVATE_KEY, "PEM")
        secrets.write("K", SecretKind.PASSPHRASE, "frase")
        val hub = hub()

        hub.service(server(id = "K", authMethod = AuthMethod.KEY, requiresPassphrase = true))
        val withPhrase = assertIs<SSHCredentials.PrivateKey>(connector.made.last().second)
        assertEquals("PEM", withPhrase.openSSHPem)
        assertEquals("frase", withPhrase.passphrase)

        hub.service(server(id = "K", authMethod = AuthMethod.KEY, requiresPassphrase = false))
        assertNull(assertIs<SSHCredentials.PrivateKey>(connector.made.last().second).passphrase)
    }

    @Test
    fun `faltan secretos - error accionable sin crear servicio`() = runTest {
        val hub = hub()
        val noPassword = assertFailsWith<MissingCredentialsException> { hub.service(server()) }
        assertTrue(noPassword.message.orEmpty().contains("contraseña"))

        assertFailsWith<MissingCredentialsException> { hub.service(server(id = "K", authMethod = AuthMethod.KEY)) }

        secrets.write("K", SecretKind.PRIVATE_KEY, "PEM")
        assertFailsWith<MissingCredentialsException> {
            hub.service(server(id = "K", authMethod = AuthMethod.KEY, requiresPassphrase = true))
        }
        assertTrue(connector.made.isEmpty())
    }

    @Test
    fun `reutiliza el servicio mientras el servidor no cambie`() = runTest {
        secrets.write("S1", SecretKind.PASSWORD, "pw")
        val hub = hub()
        val first = hub.service(server())
        assertSame(first, hub.service(server()))
        assertEquals(1, connector.made.size)
    }

    @Test
    fun `un servidor editado crea servicio nuevo y desconecta el viejo`() = runTest {
        secrets.write("S1", SecretKind.PASSWORD, "pw")
        val hub = hub()
        hub.service(server())
        val fresh = hub.service(server(host = "otro.example.com"))

        val old = connector.made.first().third
        assertNotSame(old, fresh)
        assertEquals(1, old.disconnects)
    }

    @Test
    fun `invalidate desconecta y la siguiente llamada reconecta`() = runTest {
        secrets.write("S1", SecretKind.PASSWORD, "pw")
        val hub = hub()
        hub.service(server())
        hub.invalidate("S1")
        hub.invalidate("desconocido")

        assertEquals(1, connector.made.single().third.disconnects)
        hub.service(server())
        assertEquals(2, connector.made.size)
    }

    @Test
    fun `servidor de la red local sin permiso - error propio sin crear servicio`() = runTest {
        secrets.write("S1", SecretKind.PASSWORD, "pw")
        var granted = false
        val hub = ServiceHub(connector, secrets, trust, StandardTestDispatcher(testScheduler), LocalNetworkGate({ true }, { granted }) { emptyList() })

        val error = assertFailsWith<LocalNetworkPermissionException> { hub.service(server(host = "192.168.1.40")) }
        assertEquals("192.168.1.40", error.host)
        assertTrue(error.message.orEmpty().contains("Dispositivos cercanos"))
        assertTrue(connector.made.isEmpty())

        granted = true
        hub.service(server(host = "192.168.1.40"))
        assertEquals(1, connector.made.size)
    }

    @Test
    fun `cached no abre conexiones y olvida un servidor editado`() = runTest {
        secrets.write("S1", SecretKind.PASSWORD, "pw")
        val hub = hub()
        assertNull(hub.cached(server()))
        val service = hub.service(server())
        assertSame(service, hub.cached(server()))
        assertNull(hub.cached(server(host = "otro.example.com")))
        assertEquals(1, connector.made.size)
    }

    @Test
    fun `probeAll descarta la conexión que no responde o está caída y conserva la viva`() = runTest {
        secrets.write("A", SecretKind.PASSWORD, "pw")
        secrets.write("B", SecretKind.PASSWORD, "pw")
        secrets.write("C", SecretKind.PASSWORD, "pw")
        val disconnected = mutableListOf<String>()
        val hub = ServiceHub(connector, secrets, trust, StandardTestDispatcher(testScheduler), onDisconnected = { disconnected += it })
        hub.service(server(id = "A"))
        hub.service(server(id = "B"))
        hub.service(server(id = "C"))
        val (a, b, c) = connector.made.map { it.third }
        a.listGate = kotlinx.coroutines.CompletableDeferred()
        b.listError = java.io.IOException("roto")
        c.listError = com.iaportafolio.argos.core.SSHServiceError.TmuxNotInstalled()

        val dead = hub.probeAll(timeoutMillis = 4_000)

        assertEquals(setOf("A", "B"), dead)
        assertEquals(setOf("C"), hub.connectedServerIds())
        assertEquals(listOf(1, 1, 0), listOf(a.disconnects, b.disconnects, c.disconnects))
        assertEquals(setOf("A", "B"), disconnected.toSet())
    }

    @Test
    fun `closeAll cierra todo y avisa de cada servidor`() = runTest {
        secrets.write("A", SecretKind.PASSWORD, "pw")
        secrets.write("B", SecretKind.PASSWORD, "pw")
        val disconnected = mutableListOf<String>()
        val hub = ServiceHub(connector, secrets, trust, StandardTestDispatcher(testScheduler), onDisconnected = { disconnected += it })
        hub.service(server(id = "A"))
        hub.service(server(id = "B"))

        hub.closeAll()

        assertTrue(hub.connectedServerIds().isEmpty())
        assertEquals(listOf("A", "B"), disconnected)
        assertTrue(connector.made.all { it.third.disconnects == 1 })
    }
}
