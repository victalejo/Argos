package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.SSHCredentials
import com.iaportafolio.argos.core.SSHServiceError
import com.iaportafolio.argos.core.ShellQuoting
import com.iaportafolio.argos.core.agent.PersistentAgentError
import com.iaportafolio.argos.core.projects.Project
import com.iaportafolio.argos.core.projects.ProjectError
import com.iaportafolio.argos.core.tmux.WindowNameValidator
import com.iaportafolio.argos.ssh.testing.EmbeddedSshServer
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestInstance
import org.junit.jupiter.api.io.TempDir
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermissions
import kotlin.io.path.writeText
import java.time.Instant
import kotlin.io.path.deleteIfExists
import kotlin.io.path.exists
import kotlin.io.path.readBytes
import kotlin.io.path.readText
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Operaciones de [SshjSSHService] de punta a punta: SSH real (MINA SSHD) → `/bin/sh -c` → tmux
 * real, aislado con `TMUX_TMPDIR` y `HOME` temporales (no toca las sesiones del usuario).
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class SshjTmuxIntegrationTest {

    private lateinit var workDir: Path

    private lateinit var server: EmbeddedSshServer
    private lateinit var service: SshjSSHService

    @BeforeAll
    fun start(@TempDir dir: Path) {
        workDir = dir
        SshjConnector.installSecurityProvider()
        server = EmbeddedSshServer.start(Files.createDirectories(workDir.resolve("server")), password = PASSWORD)
        service = SshjConnector().service(
            testServer(server.port),
            SSHCredentials.Password(PASSWORD),
            InMemoryTrustStore(),
        ) as SshjSSHService
    }

    @AfterEach
    fun killTmux() {
        server.killTmux()
    }

    @AfterAll
    fun stop() {
        runBlocking { service.disconnect() }
        server.close()
    }

    @Test
    fun `tmux está instalado en el servidor`() = runBlocking<Unit> {
        assertTrue(service.isTmuxInstalled())
    }

    @Test
    fun `sin servidor tmux listSessions devuelve lista vacía`() = runBlocking<Unit> {
        assertEquals(emptyList(), service.listSessions())
    }

    @Test
    fun `crea, renombra y mata sesiones con espacios y comillas`() = runBlocking<Unit> {
        service.createSession(ODD_NAME)
        assertEquals(listOf(ODD_NAME), service.listSessions().map { it.name })

        service.renameSession(ODD_NAME, RENAMED)
        assertEquals(listOf(RENAMED), service.listSessions().map { it.name })

        service.killSession(RENAMED)
        assertEquals(emptyList(), service.listSessions())
    }

    @Test
    fun `sesión duplicada da CommandFailed con el stderr de tmux`() = runBlocking<Unit> {
        service.createSession("dup")
        val error = assertFailsWith<SSHServiceError.CommandFailed> { service.createSession("dup") }
        assertContains(error.detail, "duplicate session")
    }

    @Test
    fun `matar con target exacto no afecta a sesiones con el mismo prefijo`() = runBlocking<Unit> {
        service.createSession("api")
        service.createSession("api-2")
        assertFailsWith<SSHServiceError.CommandFailed> { service.killSession("ap") }
        service.killSession("api")
        assertEquals(listOf("api-2"), service.listSessions().map { it.name })
    }

    @Test
    fun `gestiona ventanas de punta a punta`() = runBlocking<Unit> {
        service.createSession(ODD_NAME)
        val initial = service.listWindows(ODD_NAME)
        assertEquals(1, initial.size)

        service.newWindow(ODD_NAME)
        val two = service.listWindows(ODD_NAME)
        assertEquals(2, two.size)
        val second = two.last().index

        service.renameWindow(ODD_NAME, second, "ventana 'b' \"c\"")
        assertEquals("ventana 'b' \"c\"", service.listWindows(ODD_NAME).last().name)

        service.selectWindow(ODD_NAME, initial.first().index)
        assertTrue(service.listWindows(ODD_NAME).first().isActive)

        service.killWindow(ODD_NAME, second)
        assertEquals(1, service.listWindows(ODD_NAME).size)
    }

    @Test
    fun `listWindows de una sesión inexistente es vacío`() = runBlocking<Unit> {
        assertEquals(emptyList(), service.listWindows("no-existe"))
    }

    @Test
    fun `renameWindow valida el nombre antes de enviarlo`() {
        assertFailsWith<WindowNameValidator.ValidationError> {
            runBlocking { service.renameWindow("x", 0, "   ") }
        }
    }

    @Test
    fun `sendKeys teclea en el panel activo`() = runBlocking<Unit> {
        service.createSession(ODD_NAME)
        service.sendKeys(ODD_NAME, "echo 'ARGOS'_OK", enter = true)
        val capture = "tmux capture-pane -p -t ${ShellQuoting.singleQuoted("=$ODD_NAME:")}"
        withTimeout(10_000) {
            while (!service.runAgentScript(capture).contains("ARGOS_OK")) delay(100)
        }
    }

    @Test
    fun `crea la configuración de tmux solo si no existe`() = runBlocking<Unit> {
        val config = server.home.resolve(".tmux.conf")
        config.deleteIfExists()
        assertFalse(service.tmuxConfigExists())
        service.writeDefaultTmuxConfig()
        assertTrue(service.tmuxConfigExists())
        assertContains(config.readText(), "set -g mouse on")
        service.enableClipboardForwarding()
        config.deleteIfExists()
    }

    @Test
    fun `sube archivos pegados y soltados por SFTP`() = runBlocking<Unit> {
        val bytes = byteArrayOf(0, 1, 2, -1, 10, 13)
        val pasted = Path.of(service.uploadPastedFile(bytes, "png"))
        val dropped = Path.of(service.uploadDroppedFile("hola".toByteArray(), "../mi foto ñ.txt"))
        try {
            assertTrue(pasted.fileName.toString().matches(Regex("argos-pasted-\\d+\\.png")))
            assertTrue(bytes.contentEquals(pasted.readBytes()))
            assertTrue(dropped.fileName.toString().matches(Regex("argos-\\d+-mi_foto__\\.txt")))
            assertEquals("hola", dropped.readText())
            assertEquals("rw-------", PosixFilePermissions.toString(Files.getPosixFilePermissions(pasted)))
            assertEquals("rw-------", PosixFilePermissions.toString(Files.getPosixFilePermissions(dropped)))
        } finally {
            pasted.deleteIfExists()
            dropped.deleteIfExists()
        }
    }

    @Test
    fun `una subida no sigue un symlink plantado en tmp`() = runBlocking<Unit> {
        val victim = Files.createTempFile(workDir, "victima", ".txt").also { it.writeText("intacto") }
        val planted = Path.of("/tmp", "argos-symlink-${System.nanoTime()}.txt")
        Files.createSymbolicLink(planted, victim)
        val connection = SshjConnection(
            testServer(server.port),
            SSHCredentials.Password(PASSWORD),
            InMemoryTrustStore(),
            SshjConnector.Settings(),
        )
        try {
            assertFailsWith<SSHServiceError.UploadFailed> {
                connection.upload("malicioso".toByteArray(), planted.toString())
            }
            assertEquals("intacto", victim.readText())
        } finally {
            connection.disconnect()
            planted.deleteIfExists()
        }
    }

    @Test
    fun `guarda y carga proyectos en un archivo privado con copia`() = runBlocking<Unit> {
        assertEquals(emptyList(), service.loadProjects())
        val project = Project(name = "web", group = "ia", path = "/srv/web", createdAt = Instant.parse("2026-01-02T03:04:05Z"))
        service.saveProjects(listOf(project))
        service.saveProjects(listOf(project, project.copy(id = "1E2D3C4B-0000-4000-8000-000000000000", name = "api")))

        assertEquals(listOf("web", "api"), service.loadProjects().map { it.name })
        val file = server.home.resolve(".config/argos/projects.json")
        assertEquals("rw-------", PosixFilePermissions.toString(Files.getPosixFilePermissions(file)))
        assertTrue(server.home.resolve(".config/argos/projects.json.argos-backup").exists())
        assertFalse(server.home.resolve(".config/argos/projects.json.argos-tmp").exists())
    }

    @Test
    fun `proyectos inválidos lanzan InvalidFile`() = runBlocking<Unit> {
        val file = Files.createDirectories(server.home.resolve(".config/argos")).resolve("projects.json")
        Files.writeString(file, "{roto")
        try {
            assertFailsWith<ProjectError.InvalidFile> { service.loadProjects() }
        } finally {
            file.deleteIfExists()
        }
    }

    @Test
    fun `arranca y detiene un proyecto en su carpeta`() = runBlocking<Unit> {
        val folder = Files.createDirectories(server.home.resolve("proyecto x"))
        service.startProject("ia/proyecto", folder.toString(), startupCommand = "echo arrancado")
        assertEquals(listOf("ia/proyecto"), service.listSessions().map { it.name })
        assertEquals(folder.toRealPath().toString(), service.sessionFirstPanePaths()["ia/proyecto"]?.let { Path.of(it).toRealPath().toString() })
        service.stopSession("ia/proyecto")
        assertEquals(emptyList(), service.listSessions())
    }

    @Test
    fun `arrancar un proyecto sin carpeta da MissingFolder`() {
        assertFailsWith<ProjectError.MissingFolder> {
            runBlocking { service.startProject("p", "/no/existe/argos", startupCommand = null) }
        }
    }

    @Test
    fun `instala los hooks de Claude conservando settings existentes`() = runBlocking<Unit> {
        val settings = Files.createDirectories(server.home.resolve(".claude")).resolve("settings.json")
        Files.writeString(settings, """{"env":{"X":"1"}}""")
        assertFalse(service.claudeHooksInstalled())
        service.installClaudeHooks()
        assertTrue(service.claudeHooksInstalled())
        assertContains(settings.readText(), "\"X\" : \"1\"")
        assertEquals("rw-------", PosixFilePermissions.toString(Files.getPosixFilePermissions(settings)))
    }

    @Test
    fun `autoriza y revoca claves en authorized_keys`() = runBlocking<Unit> {
        val line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGg0 argos-iphone-20260101-abc"
        service.authorizeKey(line)
        val file = server.home.resolve(".ssh/authorized_keys")
        assertContains(file.readText(), line)
        service.revokeKey("argos-iphone-20260101-abc")
        assertFalse(file.readText().contains("argos-iphone"))
    }

    @Test
    fun `utilidades del agente sobre el canal exec`() = runBlocking<Unit> {
        assertTrue(service.remoteDirectoryExists(server.home.toString()))
        assertFalse(service.remoteDirectoryExists("/no/existe/argos"))
        assertEquals("hola\n", service.runAgentScript("echo hola"))
        service.killAgentProcess(999_999)
        service.gitBranch(server.home.toString()).let(::assertNull)
        service.installedCodingAgents()
        service.canUseSudoNonInteractive()
    }

    @Test
    fun `el script del agente muerto da PersistentAgentException`() {
        val error = assertFailsWith<PersistentAgentException> {
            runBlocking { service.runAgentScript("echo ARGOS_AGENT_DEAD >&2; exit 1") }
        }
        assertEquals(PersistentAgentError.NOT_RUNNING, error.error)
    }

    @Test
    fun `un script del agente que falla incluye su stderr`() {
        val error = assertFailsWith<AgentExecException> {
            runBlocking { service.runAgentScript("echo 'not logged in' >&2; exit 2") }
        }
        assertEquals("not logged in", error.detail)
    }

    private companion object {
        const val PASSWORD = "tmux-pass"
        const val ODD_NAME = "mi sesión 'rara' \"x\" \$HOME"
        const val RENAMED = "otra; echo 'pwned' \"y\""
    }
}
