package com.iaportafolio.argos.ssh.testing

import com.iaportafolio.argos.core.agent.AgentExecCommands
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermissions
import kotlin.io.path.createDirectories
import kotlin.io.path.deleteIfExists
import kotlin.io.path.writeBytes

/**
 * Instala el `claude` SIMULADO (`resources/fake-claude/claude.sh`, sin red ni consumo alguno) en
 * un `HOME` aislado, en `~/.local/bin`, donde lo encuentra `AgentExecCommands.LOCATE_CLAUDE_SCRIPT`.
 */
object FakeClaude {

    private const val RESOURCE = "/fake-claude/claude.sh"

    /** Ruta del simulado dentro del `HOME` (va la primera del PATH de [EmbeddedSshServer]). */
    const val RELATIVE_PATH = ".local/bin/claude"

    /** Si existe en el `HOME`, `claude auth status --json` dice «no logueado». */
    const val LOGGED_OUT_MARKER = ".fake-claude-logged-out"

    /** Si existe en el `HOME`: sin pausas y registra argumentos, token y stdin (solo tests). */
    const val TEST_DIRECTORY = ".fake-claude-test"

    /** Texto del script. */
    fun script(): ByteArray = checkNotNull(FakeClaude::class.java.getResourceAsStream(RESOURCE)) {
        "No se encuentra el recurso $RESOURCE"
    }.use { it.readBytes() }

    /** Instala (o actualiza) el simulado; con [testMode] crea [TEST_DIRECTORY]. Devuelve su ruta. */
    fun install(home: Path, testMode: Boolean = false): Path {
        val target = home.resolve(RELATIVE_PATH)
        target.parent.createDirectories()
        target.writeBytes(script())
        Files.setPosixFilePermissions(target, PosixFilePermissions.fromString("rwxr-xr-x"))
        if (testMode) home.resolve(TEST_DIRECTORY).createDirectories()
        return target
    }

    /** Quita el simulado (para probar «claude no instalado»). */
    fun uninstall(home: Path) {
        home.resolve(RELATIVE_PATH).deleteIfExists()
    }

    /**
     * Comprueba que lo que resuelve el servidor con el MISMO script que usa la app es el simulado.
     * Es la última barrera para no lanzar nunca el `claude` real del usuario.
     *
     * @throws IllegalStateException si resuelve otro binario.
     */
    fun verifyResolves(server: EmbeddedSshServer) {
        val expected = server.home.resolve(RELATIVE_PATH).toString()
        val located = AgentExecCommands.parseLocateClaude(server.runLocal(AgentExecCommands.LOCATE_CLAUDE_SCRIPT))
        check(located == expected) { "El servidor resuelve «claude» en $located, no en el simulado ($expected)." }
    }
}
