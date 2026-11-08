package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.SSHCredentials
import com.iaportafolio.argos.core.SSHServiceError
import com.iaportafolio.argos.core.ShellQuoting
import com.iaportafolio.argos.core.files.FileBrowserCommands
import com.iaportafolio.argos.core.files.FileBrowserException
import com.iaportafolio.argos.core.files.FilePreview
import com.iaportafolio.argos.core.files.RemoteFileEntry
import com.iaportafolio.argos.ssh.testing.EmbeddedSshServer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.consumeAsFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.Assumptions.assumeFalse
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestInstance
import org.junit.jupiter.api.io.TempDir
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermissions
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicLong
import kotlin.io.path.createDirectories
import kotlin.io.path.writeBytes
import kotlin.io.path.writeText
import kotlin.random.Random
import kotlin.test.assertContains
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Explorador de archivos de punta a punta: sshj → MINA SSHD con SFTP sobre el sistema de
 * archivos real → un árbol temporal. Cubre la contención (`..` y symlinks), la lectura por
 * bloques, la descarga en streaming, el índice y los errores traducidos.
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class SshjFileBrowserIntegrationTest {

    private lateinit var server: EmbeddedSshServer
    private lateinit var service: SshjSSHService

    /** Raíz del proyecto (ruta tal cual, sin resolver symlinks del sistema como `/var`). */
    private lateinit var root: String
    private lateinit var rootDir: Path
    private lateinit var outsideDir: Path

    private val bigFile = Random(7).nextBytes(BIG_FILE_SIZE)
    private val binaryFile = Random(11).nextBytes(BINARY_SIZE).also { it[0] = 0 }

    @BeforeAll
    fun start(@TempDir dir: Path) {
        SshjConnector.installSecurityProvider()
        server = EmbeddedSshServer.start(Files.createDirectories(dir.resolve("server")), password = PASSWORD)
        service = SshjConnector().service(
            testServer(server.port),
            SSHCredentials.Password(PASSWORD),
            InMemoryTrustStore(),
        ) as SshjSSHService
        rootDir = server.home.resolve("proyectos/demo").createDirectories()
        root = rootDir.toString()
        outsideDir = dir.resolve("fuera").createDirectories()
        buildTree()
    }

    @AfterAll
    fun stop() {
        runBlocking { service.disconnect() }
        server.close()
    }

    private fun buildTree() {
        rootDir.resolve("src").createDirectories().resolve("main.kt").writeText("fun main() = println(\"hola\")\n")
        rootDir.resolve("docs").createDirectories()
        rootDir.resolve("node_modules/lib").createDirectories().resolve("index.js").writeText("module.exports = 1\n")
        rootDir.resolve(".git").createDirectories().resolve("HEAD").writeText("ref: refs/heads/main\n")
        rootDir.resolve("dist").createDirectories().resolve("bundle.js").writeText("// generado\n")
        rootDir.resolve("README.md").writeText(README)
        rootDir.resolve("file2.txt").writeText("dos")
        rootDir.resolve("file10.txt").writeText("diez")
        rootDir.resolve(".env").writeText("SECRETO=1\n")
        rootDir.resolve("grande.bin").writeBytes(bigFile)
        rootDir.resolve("binario.dat").writeBytes(binaryFile)
        outsideDir.resolve("secreto.txt").writeText("no deberías leer esto")
        server.home.resolve("proyectos/otro").createDirectories()
        Files.createSymbolicLink(rootDir.resolve("fuera"), outsideDir)
        Files.createSymbolicLink(rootDir.resolve("secreto.txt"), outsideDir.resolve("secreto.txt"))
        Files.createSymbolicLink(rootDir.resolve("enlace-src"), rootDir.resolve("src"))
    }

    // MARK: Listar

    @Test
    fun `lista con carpetas primero, orden natural, tipos, tamaños y fechas`() = fileTest {
        val entries = service.listRemoteDirectory(root, root)
        val names = entries.map { it.name }

        assertEquals(RemoteFileEntry.sorted(entries), entries)
        assertFalse("." in names || ".." in names)
        val firstFile = entries.indexOfFirst { !it.isDirectory }
        assertTrue(entries.take(firstFile).all { it.isDirectory })
        assertTrue(entries.drop(firstFile).none { it.isDirectory })
        assertTrue(names.indexOf("file2.txt") < names.indexOf("file10.txt"))

        val readme = entries.single { it.name == "README.md" }
        assertEquals(RemoteFileEntry.Kind.FILE, readme.kind)
        assertEquals("$root/README.md", readme.path)
        assertEquals(README.toByteArray().size.toLong(), readme.size)
        assertNotNull(readme.modified)
        assertEquals(RemoteFileEntry.Kind.DIRECTORY, entries.single { it.name == "src" }.kind)
        assertEquals(RemoteFileEntry.Kind.SYMLINK, entries.single { it.name == "enlace-src" }.kind)
    }

    @Test
    fun `oculta archivos ocultos y carpetas ruidosas salvo que se pidan`() = fileTest {
        val entries = service.listRemoteDirectory(root, root)

        val visible = entries.filter { it.isVisible(showHidden = false) }.map { it.name }
        listOf(".git", ".env", "node_modules", "dist").forEach { assertFalse(it in visible, "$it no debería verse") }
        assertTrue("src" in visible && "README.md" in visible)
        assertEquals(entries.size, entries.count { it.isVisible(showHidden = true) })
    }

    @Test
    fun `lista una subcarpeta y a través de un symlink que apunta dentro de la raíz`() = fileTest {
        assertEquals(listOf("main.kt"), service.listRemoteDirectory("$root/src", root).map { it.name })

        val viaLink = service.listRemoteDirectory("$root/enlace-src", root)
        assertEquals(listOf("main.kt"), viaLink.map { it.name })
        assertEquals("$root/enlace-src/main.kt", viaLink.single().path)
        val content = service.readRemoteFile("$root/enlace-src/main.kt", root, MAX_BYTES)
        assertContains(content.data.toString(Charsets.UTF_8), "hola")
    }

    @Test
    fun `SFTP arranca en el HOME aislado de los comandos (rutas relativas)`() = fileTest {
        val names = service.listRemoteDirectory("proyectos", ".").map { it.name }
        assertTrue("demo" in names && "otro" in names, names.toString())
    }

    // MARK: Contención

    @Test
    fun `salir con dos puntos lanza OutsideProject`() = fileTest {
        val error = assertFailsWith<FileBrowserException.OutsideProject> {
            service.listRemoteDirectory("$root/..", root)
        }
        assertEquals("$root/..", error.path)
        assertFailsWith<FileBrowserException.OutsideProject> {
            service.readRemoteFile("$root/src/../../otro", root, MAX_BYTES)
        }
        assertFailsWith<FileBrowserException.OutsideProject> {
            service.downloadRemoteFile("$root/../otro", root, ByteArrayOutputStream())
        }
    }

    @Test
    fun `un symlink hacia fuera de la raíz lanza OutsideProject`() = fileTest {
        assertFailsWith<FileBrowserException.OutsideProject> { service.listRemoteDirectory("$root/fuera", root) }
        assertFailsWith<FileBrowserException.OutsideProject> {
            service.readRemoteFile("$root/secreto.txt", root, MAX_BYTES)
        }
        assertFailsWith<FileBrowserException.OutsideProject> {
            service.readRemoteFile("$root/fuera/secreto.txt", root, MAX_BYTES)
        }
        val sink = ByteArrayOutputStream()
        assertFailsWith<FileBrowserException.OutsideProject> {
            service.downloadRemoteFile("$root/secreto.txt", root, sink)
        }
        assertEquals(0, sink.size())
    }

    // MARK: Leer

    @Test
    fun `lee un archivo pequeño entero con su tamaño y fecha`() = fileTest {
        val content = service.readRemoteFile("$root/README.md", root, MAX_BYTES)

        assertEquals(README, content.data.toString(Charsets.UTF_8))
        assertEquals(README.toByteArray().size.toLong(), content.size)
        assertFalse(content.isTruncated)
        val expected = Files.getLastModifiedTime(rootDir.resolve("README.md")).toInstant().epochSecond
        assertEquals(expected, content.modified?.epochSecond)
    }

    @Test
    fun `lee solo hasta maxBytes de un archivo grande y lo marca truncado`() = fileTest {
        val limit = 300_000L // cruza el límite de un bloque de 256 KiB
        val content = service.readRemoteFile("$root/grande.bin", root, limit)

        assertEquals(limit.toInt(), content.data.size)
        assertContentEquals(bigFile.copyOf(limit.toInt()), content.data)
        assertEquals(BIG_FILE_SIZE.toLong(), content.size)
        assertTrue(content.isTruncated)

        val empty = service.readRemoteFile("$root/grande.bin", root, 0)
        assertEquals(0, empty.data.size)
        assertTrue(empty.isTruncated)
    }

    @Test
    fun `lee un binario byte a byte`() = fileTest {
        val content = service.readRemoteFile("$root/binario.dat", root, FilePreview.MAX_TEXT_BYTES)

        assertContentEquals(binaryFile, content.data)
        assertFalse(content.isTruncated)
        assertTrue(FilePreview.looksBinary(content.data))
    }

    @Test
    fun `un archivo inexistente da un error claro de no existe`() = fileTest {
        val error = assertFailsWith<RemoteFileException.NotFound> {
            service.readRemoteFile("$root/no-existe.txt", root, MAX_BYTES)
        }
        assertContains(error.message.orEmpty(), "ya no existe")
    }

    // MARK: Descargar

    @Test
    fun `descarga un archivo de varios MiB idéntico byte a byte`() = fileTest {
        val sink = DigestOutputStream()
        val written = service.downloadRemoteFile("$root/grande.bin", root, sink)

        assertEquals(BIG_FILE_SIZE.toLong(), written)
        assertEquals(BIG_FILE_SIZE.toLong(), sink.count.get())
        assertEquals(sha256(bigFile), sink.hex())
    }

    @Test
    fun `cancelar una descarga a mitad la detiene y la conexión sigue usable`() = fileTest {
        val sink = SlowOutputStream()
        val download = launch(Dispatchers.Default) { service.downloadRemoteFile("$root/grande.bin", root, sink) }
        eventually("empieza a escribir") { sink.count.get() > 0 }

        download.cancelAndJoin()

        assertTrue(download.isCancelled)
        val writtenAtCancel = sink.count.get()
        assertTrue(writtenAtCancel < BIG_FILE_SIZE, "se detuvo antes del final ($writtenAtCancel bytes)")
        Thread.sleep(SETTLE_MILLIS)
        assertEquals(writtenAtCancel, sink.count.get(), "no sigue escribiendo tras cancelar")
        assertEquals(README, service.readRemoteFile("$root/README.md", root, MAX_BYTES).data.toString(Charsets.UTF_8))
    }

    // MARK: Permisos

    @Test
    fun `un archivo o carpeta sin permisos da un error claro de permiso denegado`() = fileTest {
        val locked = rootDir.resolve("bloqueado.txt").also { it.writeText("privado") }
        val lockedDir = rootDir.resolve("cerrada").createDirectories()
        try {
            Files.setPosixFilePermissions(locked, PosixFilePermissions.fromString("---------"))
            Files.setPosixFilePermissions(lockedDir, PosixFilePermissions.fromString("---------"))
            assumeFalse(Files.isReadable(locked), "como root se puede leer igualmente: no aplica")

            val error = assertFailsWith<RemoteFileException.PermissionDenied> {
                service.readRemoteFile("$root/bloqueado.txt", root, MAX_BYTES)
            }
            assertContains(error.message.orEmpty(), "Sin permiso")
            assertFailsWith<RemoteFileException.PermissionDenied> {
                service.downloadRemoteFile("$root/bloqueado.txt", root, ByteArrayOutputStream())
            }
            assertFailsWith<RemoteFileException.PermissionDenied> {
                service.listRemoteDirectory("$root/cerrada", root)
            }
        } finally {
            Files.setPosixFilePermissions(locked, PosixFilePermissions.fromString("rw-------"))
            Files.setPosixFilePermissions(lockedDir, PosixFilePermissions.fromString("rwx------"))
            Files.delete(locked)
            Files.delete(lockedDir)
        }
    }

    // MARK: Índice

    @Test
    fun `el índice salta las carpetas ruidosas`() = fileTest {
        val index = service.indexProjectFiles(root)

        assertTrue("src/main.kt" in index && "README.md" in index && "grande.bin" in index)
        assertTrue(index.none { it.startsWith("./") })
        listOf("node_modules/", ".git/", "dist/").forEach { prefix ->
            assertTrue(index.none { it.startsWith(prefix) }, "no debería indexar $prefix")
        }
    }

    @Test
    fun `el índice respeta el límite de rutas`() = fileTest {
        val many = server.home.resolve("proyectos/enorme").createDirectories()
        repeat(FileBrowserCommands.FILE_INDEX_LIMIT + EXTRA_FILES) { Files.createFile(many.resolve("f$it.txt")) }

        val index = service.indexProjectFiles(many.toString())

        assertEquals(FileBrowserCommands.FILE_INDEX_LIMIT, index.size)
        server.runLocal("rm -rf ${ShellQuoting.singleQuoted(many.toString())}")
    }

    // MARK: Selector de carpetas

    @Test
    fun `listRemoteDirectories navega desde la carpeta personal`() = fileTest {
        val home = service.listRemoteDirectories("~")
        assertTrue(home.path == server.home.toString() || home.path == server.home.toRealPath().toString(), home.path)
        assertTrue("proyectos" in home.subdirectories, home.subdirectories.toString())

        val projects = service.listRemoteDirectories("~/proyectos")
        assertEquals(listOf("demo", "otro"), projects.subdirectories.filter { it == "demo" || it == "otro" })
        assertTrue(projects.path.endsWith("/proyectos"))

        assertFailsWith<SSHServiceError.CommandFailed> { service.listRemoteDirectories("~/no-existe-esta") }
    }

    // MARK: Concurrencia y reconexión

    @Test
    fun `listas y lecturas concurrentes funcionan con un terminal adjunto`() = fileTest {
        service.createSession("explorador")
        val control = controlChannel()
        val output = TerminalOutput()
        val attach = launch(Dispatchers.Default) {
            service.attachTerminal("explorador", 80, 24, control.consumeAsFlow(), output::append)
        }
        eventually("el terminal recibe la salida inicial") { output.bytes().isNotEmpty() }

        val results = (1..CONCURRENT_CALLS).map { i ->
            async(Dispatchers.Default) {
                if (i % 2 == 0) {
                    service.listRemoteDirectory(root, root).size
                } else {
                    service.readRemoteFile("$root/grande.bin", root, BIG_FILE_SIZE.toLong()).data.size
                }
            }
        }.awaitAll()

        val listed = service.listRemoteDirectory(root, root).size
        results.forEachIndexed { index, value ->
            assertEquals(if ((index + 1) % 2 == 0) listed else BIG_FILE_SIZE, value)
        }
        control.send(keys("echo vivo-\$((40+2))\r"))
        eventually("el terminal sigue respondiendo") { output.plainText().contains("vivo-42") }
        attach.cancelAndJoin()
        server.killTmux()
    }

    @Test
    fun `tras desconectar, el cliente SFTP se reabre en la siguiente llamada`() = fileTest {
        assertTrue(service.listRemoteDirectory(root, root).isNotEmpty())
        service.disconnect()
        assertTrue(service.listRemoteDirectory(root, root).isNotEmpty())
        assertEquals(README, service.readRemoteFile("$root/README.md", root, MAX_BYTES).data.toString(Charsets.UTF_8))
    }

    // MARK: Utilidades

    private fun fileTest(block: suspend CoroutineScope.() -> Unit) = runBlocking<Unit> {
        withTimeout(TEST_TIMEOUT_MILLIS) { coroutineScope { block() } }
    }

    /** Calcula el SHA-256 al vuelo sin guardar el contenido. */
    private class DigestOutputStream : OutputStream() {
        private val digest = MessageDigest.getInstance("SHA-256")
        val count = AtomicLong()

        override fun write(b: Int) {
            digest.update(b.toByte())
            count.incrementAndGet()
        }

        override fun write(b: ByteArray, off: Int, len: Int) {
            digest.update(b, off, len)
            count.addAndGet(len.toLong())
        }

        fun hex(): String = digest.digest().joinToString("") { "%02x".format(it) }
    }

    /** Destino lento (como una red o tarjeta lenta) para poder cancelar a mitad. */
    private class SlowOutputStream : OutputStream() {
        val count = AtomicLong()

        override fun write(b: Int) {
            write(byteArrayOf(b.toByte()), 0, 1)
        }

        override fun write(b: ByteArray, off: Int, len: Int) {
            Thread.sleep(SLOW_WRITE_MILLIS)
            count.addAndGet(len.toLong())
        }
    }

    private companion object {
        const val PASSWORD = "argos-test"
        const val TEST_TIMEOUT_MILLIS = 60_000L
        const val SETTLE_MILLIS = 300L
        const val SLOW_WRITE_MILLIS = 100L
        const val MAX_BYTES = 1024L * 1024
        const val BIG_FILE_SIZE = 5 * 1024 * 1024 + 123
        const val BINARY_SIZE = 600 * 1024
        const val EXTRA_FILES = 25
        const val CONCURRENT_CALLS = 12
        const val README = "# Demo\n\nProyecto de prueba de Argos. ñandú ✓\n"

        fun sha256(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    }
}
