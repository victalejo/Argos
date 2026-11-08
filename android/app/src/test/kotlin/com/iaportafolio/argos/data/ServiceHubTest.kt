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
}
