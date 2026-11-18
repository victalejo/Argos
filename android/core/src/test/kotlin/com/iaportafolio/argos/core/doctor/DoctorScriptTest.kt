package com.iaportafolio.argos.core.doctor

import com.iaportafolio.argos.core.ports.PortForwardServerFiles
import com.iaportafolio.argos.core.status.ClaudeHookInstaller
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

    private fun run(home: File, shell: String = "/bin/sh"): Pair<Int, String> {
        val builder = ProcessBuilder(shell, "-c", DoctorScript.command).redirectError(ProcessBuilder.Redirect.DISCARD)
        builder.environment().apply {
            clear()
            put("HOME", home.path)
            put("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            put("SHELL", "/bin/sh")
            put("LANG", "C.UTF-8")
        }
        val process = builder.start()
        process.outputStream.close()
        val output = process.inputStream.readBytes().toString(Charsets.UTF_8)
        return process.waitFor() to output
    }

    @ParameterizedTest
    @MethodSource("shells")
    fun `termina con 0, completo y sin escribir en HOME`(shell: String) {
        val home = home()
        try {
            val (status, output) = run(home, shell)
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
            assertTrue(home.listFiles().isNullOrEmpty(), "$shell escribió en HOME")
        } finally {
            home.deleteRecursively()
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
        @JvmStatic
        fun shells(): List<String> = listOf("/bin/sh", "/bin/dash", "/bin/bash").filter { File(it).canExecute() }
    }
}
