package com.iaportafolio.argos.core.doctor

import com.iaportafolio.argos.core.ports.PortForwardServerFiles
import com.iaportafolio.argos.core.status.ClaudeHookInstaller
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.MethodSource
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * El script del Doctor se EJECUTA de verdad (como `ArgosTests/DoctorScriptTests.swift`) con un HOME
 * temporal: termina con 0, no escribe nada y su salida se entiende y se evalúa sin sorpresas.
 *
 * «No escribe nada» se mide contra una línea base: lo que crean por sí solos los shells de login
 * del sistema (`"$s" -lc`, con sus perfiles) en un HOME vacío no es del Doctor. `claude` y `gh` son
 * sustitutos (no dependen de lo instalado); un caso aparte usa el `gh` real si existe. Si falla,
 * el mensaje dice QUÉ archivos aparecieron.
 */
class DoctorScriptTest {

    private fun home(settings: String? = null, projects: String? = null, skillVersion: String? = null): File {
        val home = Files.createTempDirectory("doctor-").toFile()
        settings?.let { File(home, ".claude").mkdirs(); File(home, ".claude/settings.json").writeText(it) }
        projects?.let { File(home, ".config/argos").mkdirs(); File(home, ".config/argos/projects.json").writeText(it) }
        skillVersion?.let {
            val dir = File(home, ".claude/skills/argos-puertos").apply { mkdirs() }
            File(dir, "SKILL.md").writeText("# $it\n")
            File(dir, "argos-ports").writeText("#!/bin/sh\n# $it\n")
        }
        return home
    }

    /**
     * Ejecuta [script] como `sshd` (`sh -c`) con PATH mínimo; [extraPath] va delante (sustitutos) y
     * `TMPDIR` es [tmp] (para ver qué temporales deja).
     */
    private fun run(
        home: File,
        shell: String = "/bin/sh",
        extraPath: File? = null,
        tmp: File? = null,
        script: String = DoctorScript.command,
    ): Pair<Int, String> {
        val builder = ProcessBuilder(shell, "-c", script).redirectError(ProcessBuilder.Redirect.DISCARD)
        builder.environment().apply {
            clear()
            put("HOME", home.path)
            put("PATH", listOfNotNull(extraPath?.path, SYSTEM_PATH).joinToString(":"))
            put("SHELL", "/bin/sh")
            put("LANG", "C.UTF-8")
            tmp?.let { put("TMPDIR", it.path) }
        }
        val process = builder.start()
        process.outputStream.close()
        val output = process.inputStream.readBytes().toString(Charsets.UTF_8)
        return process.waitFor() to output
    }

    /** Rutas (relativas) de todo lo que hay bajo [root]. */
    private fun tree(root: File): Set<String> =
        root.walkTopDown().filter { it != root }.map { it.relativeTo(root).path }.toSortedSet()

    /** Lo que crean los shells de login del Doctor por sí solos, en un HOME vacío y el mismo entorno. */
    private fun loginBaseline(shell: String, extraPath: File?): Set<String> {
        val home = home()
        try {
            run(home, shell, extraPath, script = BASELINE_SCRIPT)
            return tree(home)
        } finally {
            home.deleteRecursively()
        }
    }

    /** `claude` y `gh` sustitutos: anotan (fuera del HOME) con qué carpeta de configuración corren. */
    private fun stubs(withGh: Boolean = true): File {
        val bin = Files.createTempDirectory("doctor-bin-").toFile()
        fun stub(name: String, body: String) = File(bin, name).apply {
            writeText("#!/bin/sh\n$body\n")
            setExecutable(true)
        }
        val d = "$"
        stub(
            "claude",
            "printf '%s\\n' \"$d{CLAUDE_CONFIG_DIR:-}\" >> '${bin.path}/claude.dirs'\n" +
                "case \"${d}1\" in --version) echo '2.1.5 (Claude Code)';; auth) echo '{\"loggedIn\": false}';; esac",
        )
        if (withGh) {
            stub(
                "gh",
                "printf '%s|%s\\n' \"$d{GH_CONFIG_DIR:-}\" \"$d{GH_NO_UPDATE_NOTIFIER:-}\" >> '${bin.path}/gh.dirs'\n" +
                    // Como el gh real: crea su configuración al arrancar.
                    "if [ -n \"${d}GH_CONFIG_DIR\" ]; then mkdir -p \"${d}GH_CONFIG_DIR\" && : > \"${d}GH_CONFIG_DIR/config.yml\"; fi\n" +
                    "case \"${d}1\" in --version) echo 'gh version 2.45.0';; " +
                    "auth) echo 'You are not logged into any GitHub hosts. Run gh auth login' >&2; exit 1;; esac",
            )
        }
        return bin
    }

    /** El Doctor no añade nada al HOME más allá de lo que hacen los perfiles de login. */
    private fun assertNothingWritten(home: File, baseline: Set<String>, shell: String) {
        val created = tree(home)
        val owned = created.filter { it.startsWith(".config/argos") || it.startsWith(".claude") || it.startsWith(".config/gh") }
        assertTrue(owned.isEmpty(), "$shell creó en HOME rutas de Argos, Claude o gh: $owned")
        val extra = created - baseline
        assertTrue(extra.isEmpty(), "$shell escribió en HOME: $extra (los perfiles de login solos crean: $baseline)")
    }

    @ParameterizedTest
    @MethodSource("shells")
    fun `termina con 0, completo y sin escribir en HOME`(shell: String) {
        val home = home()
        val bin = stubs()
        val tmp = Files.createTempDirectory("doctor-tmp-").toFile()
        try {
            val baseline = loginBaseline(shell, bin)
            val (status, output) = run(home, shell, bin, tmp)
            assertEquals(0, status, shell)
            val facts = DoctorFacts.parse(output)
            assertTrue(facts.isComplete, "$shell: $output")
            assertNotNull(facts["os"])
            assertNotNull(facts.numbers("disk.home", 2), output)
            assertEquals("missing", facts["hooks.settings"])
            assertEquals("missing", facts["skill.ports"])
            assertEquals("missing", facts["projects.file"])
            assertEquals("yes", facts["locale.env"])
            assertTrue((facts["clock"]?.toLongOrNull() ?: 0) > 1_700_000_000)
            assertEquals(18, DoctorEvaluator.evaluate(facts).size)
            assertEquals("out", facts["gh.auth"], output)
            assertNothingWritten(home, baseline, shell)
            // Sin configuración propia, claude y gh la reciben en una carpeta temporal FUERA del HOME
            // (gh, sin avisos de actualización) que el Doctor borra al terminar.
            // (El claude sustituto solo se encuentra si los perfiles de login conservan el PATH:
            // el /etc/profile de Debian lo reinicia; en macOS lo prueba DoctorScriptTests.swift.)
            val claudeDirs = File(bin, "claude.dirs").takeIf { it.exists() }?.readLines().orEmpty()
            assertEquals(facts["claude.present"] == "yes", claudeDirs.isNotEmpty(), output)
            val ghLines = File(bin, "gh.dirs").readLines()
            val dirs = claudeDirs + ghLines.map { it.substringBefore('|') }
            assertTrue(ghLines.isNotEmpty())
            dirs.forEach { dir ->
                assertTrue(dir.isNotEmpty() && !dir.startsWith(home.path) && !File(dir).exists(), "carpeta de config: «$dir»")
            }
            assertTrue(ghLines.all { it.endsWith("|1") }, "gh sin GH_NO_UPDATE_NOTIFIER: $ghLines")
            assertTrue(tree(tmp).isEmpty(), "quedaron temporales: ${tree(tmp)}")
        } finally {
            listOf(home, bin, tmp).forEach { it.deleteRecursively() }
        }
    }

    @Test
    fun `con configuracion propia de claude y gh se usan las suyas`() {
        val home = home(settings = "{}")
        File(home, ".config/gh").mkdirs()
        val bin = stubs()
        try {
            run(home, extraPath = bin)
            File(bin, "claude.dirs").takeIf { it.exists() }?.let { assertEquals(listOf(""), it.readLines().distinct()) }
            assertEquals(
                listOf("${home.path}/.config/gh"),
                File(bin, "gh.dirs").readLines().map { it.substringBefore('|') }.distinct(),
            )
        } finally {
            listOf(home, bin).forEach { it.deleteRecursively() }
        }
    }

    /** Con el `gh` REAL de la máquina (el runner de GitHub lo trae); se salta si no hay. */
    @ParameterizedTest
    @MethodSource("shells")
    fun `con el gh real tampoco escribe en HOME`(shell: String) {
        assumeTrue(SYSTEM_PATH.split(":").any { File(it, "gh").canExecute() }, "esta máquina no tiene gh")
        val home = home()
        val bin = stubs(withGh = false)
        try {
            val baseline = loginBaseline(shell, bin)
            val (status, output) = run(home, shell, bin)
            val facts = DoctorFacts.parse(output)
            assertEquals(0, status, shell)
            assertTrue(facts.isComplete, output)
            assertEquals("yes", facts["gh.present"], output)
            assertNothingWritten(home, baseline, shell)
        } finally {
            listOf(home, bin).forEach { it.deleteRecursively() }
        }
    }

    @Test
    fun `lee settings, skill y projects json del HOME`() {
        val settings = """{"hooks": {"Stop": [{"hooks": [{"command": "x # ${ClaudeHookInstaller.MARKER}"}]}]}}"""
        val home = home(settings, """{"version": 3, "projects": []}""", PortForwardServerFiles.TOOL_VERSION)
        try {
            val facts = DoctorFacts.parse(run(home).second)
            assertEquals("ok", facts["hooks.settings"])
            assertEquals("1", facts["hooks.marker"])
            assertEquals("current", facts["skill.ports"])
            assertEquals("ok", facts["projects.file"])
            assertEquals("3", facts["projects.version"])
        } finally {
            home.deleteRecursively()
        }
    }

    @Test
    fun `skill antigua, projects json roto y settings sin hooks de Argos`() {
        val home = home("{}", "{ no es json", "argos-ports v1")
        try {
            val facts = DoctorFacts.parse(run(home).second)
            assertEquals("outdated", facts["skill.ports"])
            assertEquals("0", facts["hooks.marker"])
            val checks = DoctorEvaluator.evaluate(facts).associateBy { it.id }
            // Sin python3 no se puede validar el JSON (queda en «unknown»); con él, es un problema.
            if (facts["projects.json"] == "invalid") assertEquals(DoctorStatus.PROBLEM, checks[DoctorCheckID.PROJECTS_FILE]?.status)
            assertEquals(DoctorFix.InstallPortsSkill(isUpdate = true), checks[DoctorCheckID.PORTS_SKILL]?.fix)
            assertEquals(DoctorFix.InstallClaudeHooks(isUpdate = false), checks[DoctorCheckID.CLAUDE_HOOKS]?.fix)
        } finally {
            home.deleteRecursively()
        }
    }

    companion object {
        private const val SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"

        /** Solo la búsqueda de `claude` del Doctor por los shells de login (la línea base). */
        private const val BASELINE_SCRIPT =
            "for s in \"\$SHELL\" bash zsh sh; do [ -n \"\$s\" ] || continue; " +
                "\"\$s\" -lc 'command -v claude' >/dev/null 2>&1 </dev/null; done; exit 0"

        @JvmStatic
        fun shells(): List<String> = listOf("/bin/sh", "/bin/dash", "/bin/bash").filter { File(it).canExecute() }
    }
}
