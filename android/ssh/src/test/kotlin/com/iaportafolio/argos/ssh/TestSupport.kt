package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.HostKeyTrustStore
import com.iaportafolio.argos.core.Server
import java.nio.file.Path
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/** Almacén TOFU en memoria para los tests. */
class InMemoryTrustStore(initial: Map<String, String> = emptyMap()) : HostKeyTrustStore {
    private val known = ConcurrentHashMap(initial)

    val entries: Map<String, String> get() = known.toMap()

    override fun trustedFingerprint(endpoint: String): String? = known[endpoint]

    override fun trust(endpoint: String, fingerprint: String) {
        known[endpoint] = fingerprint
    }

    override fun forget(endpoint: String) {
        known.remove(endpoint)
    }
}

/** Servidor de prueba apuntando al embebido. */
fun testServer(port: Int, username: String = "argos"): Server =
    Server(name = "test", host = "127.0.0.1", port = port, username = username)

/** Ejecuta un proceso local (ssh-keygen…) y devuelve su salida; falla si no termina bien. */
fun runProcess(vararg command: String, workDir: Path? = null): String {
    val process = ProcessBuilder(*command)
        .redirectErrorStream(true)
        .apply { workDir?.let { directory(it.toFile()) } }
        .start()
    val output = process.inputStream.bufferedReader().readText()
    check(process.waitFor(30, TimeUnit.SECONDS) && process.exitValue() == 0) {
        "Falló ${command.joinToString(" ")}: $output"
    }
    return output
}

/** Huella `SHA256:…` que imprime `ssh-keygen -l -f <archivo>` (segundo campo). */
fun sshKeygenFingerprint(file: Path): String = runProcess("ssh-keygen", "-l", "-E", "sha256", "-f", file.toString())
    .trim()
    .split(" ")[1]
