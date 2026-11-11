package com.iaportafolio.argos.testing

import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.ports.ActivePortForward
import com.iaportafolio.argos.core.ports.ListeningPort
import com.iaportafolio.argos.core.ports.PortForwardIdlePolicy
import com.iaportafolio.argos.core.ports.PortForwardOperations
import com.iaportafolio.argos.core.ports.PortForwardRequest
import com.iaportafolio.argos.data.PortForwardSettingsStore

/** Preferencia del cierre automático en memoria. */
class InMemoryPortForwardSettings(override var idleMinutes: Int = PortForwardIdlePolicy.DEFAULT_MINUTES) : PortForwardSettingsStore

/** [SSHServicing] de tmux ([FakeSSHService]) + túneles en memoria (port del `MockSSHService`). */
class FakePortForwardService(base: FakeSSHService = FakeSSHService()) : SSHServicing by base, PortForwardOperations {
    var listening: List<ListeningPort> = emptyList()
    val forwards = mutableListOf<ActivePortForward>()

    /** Si no es `null`, [startPortForward] lanza este error. */
    var forwardError: Exception? = null

    /** Puertos locales «ocupados»: el fake asigna el siguiente libre. */
    var busyLocalPorts: Set<Int> = emptySet()
    var listRequests = 0
    private var nextId = 0

    override suspend fun listeningPorts(): List<ListeningPort> {
        listRequests++
        return listening
    }

    override suspend fun startPortForward(remotePort: Int, targetHost: String, preferredLocalPort: Int): ActivePortForward {
        forwardError?.let { throw it }
        var local = preferredLocalPort
        while (local in busyLocalPorts) local++
        return ActivePortForward("t${nextId++}", remotePort, targetHost, local).also { forwards += it }
    }

    override suspend fun stopPortForward(id: String) {
        forwards.removeAll { it.id == id }
    }

    override suspend fun activePortForwards(): List<ActivePortForward> = forwards.toList()

    val requests = mutableListOf<PortForwardRequest>()
    val dismissed = mutableListOf<Int>()

    override suspend fun pendingPortForwardRequests(): List<PortForwardRequest> = requests.toList()

    override suspend fun dismissPortForwardRequest(port: Int) {
        dismissed += port
        requests.removeAll { it.port == port }
    }
}
