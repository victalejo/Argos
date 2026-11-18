package com.iaportafolio.argos.core.homefile

import org.junit.jupiter.api.io.TempDir
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.FileTime
import java.nio.file.attribute.PosixFilePermissions
import java.time.Instant
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.io.path.createDirectories
import kotlin.io.path.exists
import kotlin.io.path.readText
import kotlin.io.path.writeText
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Paridad con `HomeFileScriptsTests` y `ProjectsUpdaterTests` de Swift: los scripts son byte a byte
 * los de `RemotePrivateFile.swift` (goldens generados con el código Swift real) y se ejecutan DE
 * VERDAD con `/bin/sh` en un `HOME` temporal.
 */
class HomeFileScriptsTest {

    private val projects = ".config/argos/projects.json"
    private val token = "0123456789abcdef0123456789abcdef"

    private fun golden(name: String): String =
        assertNotNull(javaClass.getResource("/swift-golden/$name.txt"), "falta $name").readText(Charsets.UTF_8)

    @Test
    fun `los scripts son los de Swift byte a byte`() {
        assertEquals(golden("homefile-prepare"), HomeFileScripts.prepare(projects, token))
        assertEquals(golden("homefile-prepare-claude"), HomeFileScripts.prepare(".claude/settings.json", token))
        assertEquals(
            golden("homefile-commit-any"),
            HomeFileScripts.commit(".claude/settings.json", token, HomeFileExpectation.Any, ".argos-backup"),
        )
        assertEquals(golden("homefile-commit-absent"), HomeFileScripts.commit(projects, token, HomeFileExpectation.AbsentOrEmpty, ".argos-backup"))
        assertEquals(
            golden("homefile-commit-fingerprint"),
            HomeFileScripts.commit(projects, token, HomeFileExpectation.Fingerprint("1220704766 1"), ".argos-backup"),
        )
        assertEquals(golden("homefile-commit-nobackup"), HomeFileScripts.commit(projects, token, HomeFileExpectation.Fingerprint("it's"), null))
    }

    @Test
    fun `la huella coincide con el cksum de POSIX y con Swift`() {
        val expected = golden("cksum").split("\n")
        val inputs = listOf(ByteArray(0), "a".toByteArray(), "ñandú 123456789".toByteArray(), "x".repeat(70_000).toByteArray())
        assertEquals(expected, inputs.map(PosixChecksum::fingerprint))
        assertEquals(null, PosixChecksum.expectedFingerprint(""))
    }

    @Test
    fun `la huella calculada aqui es la que imprime cksum en el servidor`(@TempDir home: Path) {
        val file = home.resolve("f.txt").also { it.writeText("{\n  \"version\" : 1 ñ\n}") }
        val (_, output) = sh(home, "set -- \$(cksum < \"\$HOME/f.txt\"); printf '%s %s' \"\$1\" \"\$2\"")
        assertEquals(PosixChecksum.fingerprint(Files.readAllBytes(file)), output)
    }

    @Test
    fun `escribe si la huella coincide, deja copia y rechaza si cambio`(@TempDir home: Path) {
        assertEquals(0, write("uno", home, HomeFileExpectation.AbsentOrEmpty))
        assertEquals("uno", contents(home))
        assertEquals(HomeFileScripts.CONFLICT_EXIT_CODE, write("dos", home, HomeFileExpectation.AbsentOrEmpty))
        assertEquals("uno", contents(home))

        val fingerprint = PosixChecksum.fingerprint("uno".toByteArray())
        assertEquals(0, write("dos", home, HomeFileExpectation.Fingerprint(fingerprint)))
        assertEquals("dos", contents(home))
        assertEquals("uno", contents(home, ".argos-backup"))
        assertEquals(HomeFileScripts.CONFLICT_EXIT_CODE, write("tres", home, HomeFileExpectation.Fingerprint(fingerprint)))
        assertEquals("dos", contents(home))
        assertFalse(home.resolve("$projects.argos-lock").exists())
        assertEquals("rw-------", PosixFilePermissions.toString(Files.getPosixFilePermissions(home.resolve(projects))))
    }

    @Test
    fun `no reemplaza un enlace simbolico ni escribe a traves de una copia que lo sea`(@TempDir home: Path) {
        val directory = home.resolve(".config/argos").createDirectories()
        val outside = home.resolve("fuera.txt").also { it.writeText("intacto") }
        directory.resolve("projects.json").writeText("viejo")
        Files.createSymbolicLink(directory.resolve("projects.json.argos-backup"), outside)
        assertEquals(0, write("nuevo", home, HomeFileExpectation.Any))
        assertEquals("intacto", outside.readText())
        assertEquals("viejo", contents(home, ".argos-backup"))

        Files.delete(directory.resolve("projects.json"))
        Files.createSymbolicLink(directory.resolve("projects.json"), outside)
        assertEquals(HomeFileScripts.SYMLINK_EXIT_CODE, write("otro", home, HomeFileExpectation.Any))
        assertEquals("intacto", outside.readText())
    }

    @Test
    fun `un cerrojo abandonado se recupera y uno reciente da 76 sin escribir`(@TempDir home: Path) {
        val lock = home.resolve("$projects.argos-lock").createDirectories()
        Files.setLastModifiedTime(lock, FileTime.from(Instant.now().minusSeconds(300)))
        assertEquals(0, write("uno", home, HomeFileExpectation.Any))
        assertEquals("uno", contents(home))
        assertFalse(lock.exists())

        // Otro dispositivo lo tiene ahora mismo: tras 10 intentos de 1 s, 76 y el temporal borrado.
        lock.createDirectories()
        assertEquals(HomeFileScripts.LOCKED_EXIT_CODE, write("dos", home, HomeFileExpectation.Any))
        assertEquals("uno", contents(home))
        assertTrue(lock.exists())
    }

    @Test
    fun `solo admite rutas fijas y simples`() {
        assertTrue(HomeFileScripts.isSafe(".config/argos/projects.json"))
        assertTrue(HomeFileScripts.isSafe(".claude/settings.json"))
        assertFalse(HomeFileScripts.isSafe("../etc/passwd"))
        assertFalse(HomeFileScripts.isSafe("/etc/passwd"))
        assertFalse(HomeFileScripts.isSafe("a\"; rm -rf ~; \".json"))
        assertFalse(HomeFileScripts.isSafe("\$(id).json"))
        assertFalse(HomeFileScripts.isSafe(""))
    }

    /** Los tres pasos de `writeHomeFile` de Swift; la subida SFTP es aquí una escritura local. */
    private fun write(text: String, home: Path, expectation: HomeFileExpectation, backup: String? = ".argos-backup"): Int {
        val token = UUID.randomUUID().toString().replace("-", "").lowercase()
        val (prepared, printedHome) = sh(home, HomeFileScripts.posixShell(HomeFileScripts.prepare(projects, token)))
        assertEquals(0, prepared)
        assertEquals(home.toString(), printedHome)
        val temporary = Path.of(assertNotNull(HomeFileScripts.temporaryPath(printedHome, projects, token)))
        temporary.writeText(text)
        val (code, _) = sh(home, HomeFileScripts.posixShell(HomeFileScripts.commit(projects, token, expectation, backup)))
        assertFalse(temporary.exists(), "el temporal debe desaparecer")
        return code
    }

    private fun contents(home: Path, suffix: String = ""): String? = home.resolve(projects + suffix).takeIf { it.exists() }?.readText()

    /** Como el shell de login por SSH: `/bin/sh -c <comando>`. */
    private fun sh(home: Path, command: String): Pair<Int, String> {
        val process = ProcessBuilder("/bin/sh", "-c", command)
            .apply { environment()["HOME"] = home.toString() }
            .redirectError(ProcessBuilder.Redirect.DISCARD)
            .start()
        val output = process.inputStream.bufferedReader().readText()
        check(process.waitFor(60, TimeUnit.SECONDS)) { "el script no terminó" }
        return process.exitValue() to output
    }
}
