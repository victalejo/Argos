package com.iaportafolio.argos.core.doctor

import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Paridad con `ArgosTests/DoctorEvaluatorTests.swift` (parser y reglas de severidad). */
class DoctorEvaluatorTest {

    private val sample = listOf(
        "format" to "1", "os" to "Linux", "arch" to "x86_64", "shell" to "bash",
        "clock" to "1800000000", "pm" to "apt-get",
        "tmux.present" to "yes", "tmux.version" to "tmux 3.3a",
        "git.present" to "yes", "git.version" to "git version 2.43.0",
        "claude.present" to "yes", "claude.version" to "2.1.5 (Claude Code)", "claude.auth" to "in",
        "gh.present" to "yes", "gh.version" to "gh version 2.45.0 (2024-03-01)", "gh.auth" to "in",
        "tool.timeout" to "yes", "tool.cksum" to "yes", "tool.base64" to "yes", "tool.python3" to "yes",
        "tool.mkfifo" to "yes", "tool.nohup" to "yes", "tool.awk" to "yes",
        "tool.base64d" to "yes", "tool.findprintf" to "yes",
        "disk.home" to "100000000 60000000", "disk.tmp" to "50000000 40000000",
        "mem" to "16000000 9000000 2000000 1900000", "claude.procs" to "2 800000",
        "sshd.config" to "readable", "sshd.maxsessions" to "default", "fail2ban" to "absent",
        "hooks.settings" to "ok", "hooks.marker" to "9", "skill.ports" to "current",
        "projects.file" to "ok", "projects.json" to "valid", "projects.version" to "1",
        "locale.avail" to "yes", "locale.env" to "yes", "locale.lang" to "en_US.UTF-8",
        "done" to "1",
    )

    private fun output(overrides: Map<String, String> = emptyMap(), removing: Set<String> = emptySet()): String {
        val lines = sample.filter { it.first !in removing }
        val text = lines.map { (key, value) -> "$key=${overrides[key] ?: value}" } +
            overrides.filterKeys { key -> lines.none { it.first == key } }.map { (key, value) -> "$key=$value" }
        return text.joinToString("\n") + "\n"
    }

    private fun evaluate(
        overrides: Map<String, String> = emptyMap(),
        removing: Set<String> = emptySet(),
        hooksUpToDate: Boolean? = true,
        skewSeconds: Long = 0,
    ): Map<DoctorCheckID, DoctorCheck> {
        val facts = DoctorFacts.parse(output(overrides, removing))
        val context = DoctorEvaluator.Context(Instant.ofEpochSecond(1_800_000_000 - skewSeconds), hooksUpToDate)
        return DoctorEvaluator.evaluate(facts, context).associateBy { it.id }
    }

    private fun status(id: DoctorCheckID, overrides: Map<String, String> = emptyMap()) = evaluate(overrides)[id]?.status

    // MARK: DoctorFacts

    @Test
    fun `ignora ruido, toma el primer valor y exige el final`() {
        val facts = DoctorFacts.parse("Welcome to Ubuntu\nexport FOO=bar\nos=Linux\nos=Otro\nWARNING: x\nnota=dentro=igual\ndone=1\n")
        assertEquals("Linux", facts["os"])
        assertEquals("dentro=igual", facts["nota"])
        assertNull(facts["FOO"])
        assertTrue(facts.isComplete)
        assertFalse(DoctorFacts.parse("os=Linux\n").isComplete)
    }

    @Test
    fun `flag y numbers son estrictos`() {
        val facts = DoctorFacts.parse("a=yes\nb=no\nc=quizas\nn=10 20\nbad=10 x\nneg=-1 2\nshort=10\nblank=   \n")
        assertEquals(true, facts.flag("a"))
        assertEquals(false, facts.flag("b"))
        assertNull(facts.flag("c"))
        assertEquals(listOf(10L, 20L), facts.numbers("n", 2))
        assertNull(facts.numbers("bad", 2))
        assertNull(facts.numbers("neg", 2))
        assertNull(facts.numbers("short", 2))
        assertNull(facts["blank"])
    }

    @Test
    fun `versiones extrae la primera secuencia y compara por partes`() {
        assertEquals(listOf(3, 3), DoctorVersion.parse("tmux 3.3a")?.parts)
        assertEquals(listOf(2, 39, 2), DoctorVersion.parse("git version 2.39.2 (Apple Git-143)")?.parts)
        assertEquals(listOf(3, 5), DoctorVersion.parse("tmux next-3.5")?.parts)
        assertNull(DoctorVersion.parse("tmux master"))
        assertTrue(DoctorVersion(2, 9) < DoctorVersion(2, 26))
        assertEquals(DoctorVersion(2, 26), DoctorVersion(2, 26, 0))
        assertFalse(DoctorVersion(2, 26) < DoctorVersion(2, 26, 0))
    }

    // MARK: Reglas

    @Test
    fun `un servidor sano no tiene avisos ni problemas`() {
        val checks = evaluate()
        assertEquals(DoctorCheckID.entries.size, checks.size)
        val result = DoctorResult(checks.values.toList(), Instant.EPOCH)
        assertEquals(DoctorStatus.OK, result.overall, checks.values.filter { it.status != DoctorStatus.OK }.toString())
        assertEquals("Todo en orden.", result.summary)
    }

    @Test
    fun `tmux ausente es un problema con el comando del gestor y antiguo es aviso`() {
        val missing = evaluate(mapOf("tmux.present" to "no", "pm" to "dnf"))[DoctorCheckID.TMUX]
        assertEquals(DoctorStatus.PROBLEM, missing?.status)
        assertEquals(DoctorFix.CopyCommand("sudo dnf install -y tmux"), missing?.fix)
        assertNull(evaluate(mapOf("tmux.present" to "no", "pm" to ""))[DoctorCheckID.TMUX]?.fix)
        assertEquals(DoctorStatus.WARNING, status(DoctorCheckID.TMUX, mapOf("tmux.version" to "tmux 2.8")))
        assertEquals(DoctorStatus.OK, status(DoctorCheckID.TMUX, mapOf("tmux.version" to "tmux next-3.5")))
        assertEquals(DoctorStatus.OK, status(DoctorCheckID.TMUX, mapOf("tmux.version" to "tmux master")))
    }

    @Test
    fun `git avisa por debajo de 2_26 y si falta`() {
        assertEquals(DoctorStatus.WARNING, status(DoctorCheckID.GIT, mapOf("git.version" to "git version 2.25.1")))
        assertEquals(DoctorStatus.OK, status(DoctorCheckID.GIT, mapOf("git.version" to "git version 2.26.0")))
        assertEquals(DoctorStatus.WARNING, status(DoctorCheckID.GIT, mapOf("git.version" to "git version 1.8.3.1")))
        assertEquals(
            DoctorFix.CopyCommand("sudo pacman -S --noconfirm git"),
            evaluate(mapOf("git.present" to "no", "pm" to "pacman"))[DoctorCheckID.GIT]?.fix,
        )
        assertEquals(DoctorStatus.WARNING, status(DoctorCheckID.GIT, mapOf("git.present" to "no")))
    }

    @Test
    fun `claude y gh instalado, con sesion, sin sesion y sin comprobar`() {
        assertEquals(DoctorStatus.OK, status(DoctorCheckID.CLAUDE))
        assertEquals(DoctorStatus.WARNING, status(DoctorCheckID.CLAUDE, mapOf("claude.auth" to "out")))
        assertEquals(DoctorStatus.UNKNOWN, status(DoctorCheckID.CLAUDE, mapOf("claude.auth" to "unknown")))
        assertEquals(
            DoctorFix.CopyCommand(DoctorInstallHints.CLAUDE_INSTALL),
            evaluate(mapOf("claude.present" to "no"))[DoctorCheckID.CLAUDE]?.fix,
        )
        assertEquals(DoctorFix.CopyCommand("gh auth login"), evaluate(mapOf("gh.auth" to "out"))[DoctorCheckID.GH]?.fix)
        assertEquals(DoctorFix.CopyCommand("brew install gh"), evaluate(mapOf("gh.present" to "no", "pm" to "brew"))[DoctorCheckID.GH]?.fix)
        assertEquals(DoctorStatus.UNKNOWN, status(DoctorCheckID.GH, mapOf("gh.auth" to "unknown")))
    }

    @Test
    fun `utilidades dicen lo que falta y python3 nunca es un fallo`() {
        val missing = evaluate(mapOf("tool.findprintf" to "no", "tool.timeout" to "no"))[DoctorCheckID.TOOLS]
        assertEquals(DoctorStatus.WARNING, missing?.status)
        assertTrue(missing?.detail?.contains("find con -printf") == true)
        assertTrue(missing?.detail?.contains("Enviar al Mac") == true)
        assertNull(evaluate(mapOf("os" to "Darwin", "tool.findprintf" to "no"))[DoctorCheckID.TOOLS]?.fix)
        assertEquals(DoctorStatus.OK, status(DoctorCheckID.PYTHON, mapOf("tool.python3" to "no")))
        val unknown = evaluate(
            removing = setOf("tool.timeout", "tool.cksum", "tool.base64d", "tool.mkfifo", "tool.nohup", "tool.findprintf", "tool.awk"),
        )
        assertEquals(DoctorStatus.UNKNOWN, unknown[DoctorCheckID.TOOLS]?.status)
    }

    @Test
    fun `disco con umbrales de aviso y problema`() {
        assertEquals(DoctorStatus.WARNING, status(DoctorCheckID.DISK_HOME, mapOf("disk.home" to "100000000 900000")))
        assertEquals(DoctorStatus.PROBLEM, status(DoctorCheckID.DISK_HOME, mapOf("disk.home" to "100000000 100000")))
        assertEquals(DoctorStatus.WARNING, status(DoctorCheckID.DISK_TMP, mapOf("disk.tmp" to "1000000 100000")))
        assertEquals(DoctorStatus.PROBLEM, status(DoctorCheckID.DISK_TMP, mapOf("disk.tmp" to "1000000 40000")))
        assertEquals(DoctorStatus.UNKNOWN, status(DoctorCheckID.DISK_HOME, mapOf("disk.home" to "basura")))
    }

    @Test
    fun `memoria, swap y procesos de Claude`() {
        assertEquals(DoctorStatus.WARNING, status(DoctorCheckID.MEMORY, mapOf("mem" to "16000000 800000 0 0")))
        assertEquals(DoctorStatus.PROBLEM, status(DoctorCheckID.MEMORY, mapOf("mem" to "16000000 200000 0 0")))
        assertEquals(DoctorStatus.WARNING, status(DoctorCheckID.SWAP, mapOf("mem" to "2000000 1500000 0 0")))
        assertEquals(DoctorStatus.OK, status(DoctorCheckID.SWAP, mapOf("mem" to "16000000 9000000 0 0")))
        assertEquals(DoctorStatus.WARNING, status(DoctorCheckID.SWAP, mapOf("mem" to "8000000 4000000 1000000 100000")))
        assertEquals(DoctorStatus.WARNING, status(DoctorCheckID.CLAUDE_PROCESSES, mapOf("claude.procs" to "5 7000000")))
        assertEquals(DoctorStatus.PROBLEM, status(DoctorCheckID.CLAUDE_PROCESSES, mapOf("claude.procs" to "9 12000000")))
        assertEquals(DoctorStatus.OK, status(DoctorCheckID.CLAUDE_PROCESSES, mapOf("claude.procs" to "0 0")))
        val mac = evaluate(removing = setOf("mem"))
        assertEquals(DoctorStatus.UNKNOWN, mac[DoctorCheckID.MEMORY]?.status)
        assertEquals(DoctorStatus.UNKNOWN, mac[DoctorCheckID.SWAP]?.status)
    }

    @Test
    fun `MaxSessions avisa por debajo de 6 e ilegible no se pudo comprobar`() {
        assertEquals(DoctorStatus.OK, status(DoctorCheckID.MAX_SESSIONS))
        assertEquals(DoctorStatus.WARNING, status(DoctorCheckID.MAX_SESSIONS, mapOf("sshd.maxsessions" to "4")))
        assertEquals(DoctorStatus.OK, status(DoctorCheckID.MAX_SESSIONS, mapOf("sshd.maxsessions" to "6")))
        assertEquals(DoctorStatus.UNKNOWN, status(DoctorCheckID.MAX_SESSIONS, mapOf("sshd.config" to "unreadable")))
        assertEquals(DoctorStatus.UNKNOWN, status(DoctorCheckID.MAX_SESSIONS, mapOf("sshd.maxsessions" to "muchas")))
    }

    @Test
    fun `fail2ban es solo informativo`() {
        for (state in listOf("running", "installed", "absent")) {
            assertEquals(DoctorStatus.OK, status(DoctorCheckID.FAIL2BAN, mapOf("fail2ban" to state)))
        }
    }

    @Test
    fun `hooks de Claude ausentes, desactualizados y al dia`() {
        val install = DoctorFix.InstallClaudeHooks(isUpdate = false)
        assertEquals(install, evaluate(mapOf("hooks.settings" to "missing"))[DoctorCheckID.CLAUDE_HOOKS]?.fix)
        assertEquals(install, evaluate(mapOf("hooks.marker" to "0"))[DoctorCheckID.CLAUDE_HOOKS]?.fix)
        assertEquals(DoctorFix.InstallClaudeHooks(isUpdate = true), evaluate(hooksUpToDate = false)[DoctorCheckID.CLAUDE_HOOKS]?.fix)
        assertEquals(DoctorStatus.OK, evaluate(hooksUpToDate = true)[DoctorCheckID.CLAUDE_HOOKS]?.status)
        assertEquals(DoctorStatus.OK, evaluate(hooksUpToDate = null)[DoctorCheckID.CLAUDE_HOOKS]?.status)
        assertEquals(DoctorStatus.UNKNOWN, status(DoctorCheckID.CLAUDE_HOOKS, mapOf("hooks.settings" to "unreadable")))
    }

    @Test
    fun `skill de puertos`() {
        assertEquals(DoctorFix.InstallPortsSkill(isUpdate = false), evaluate(mapOf("skill.ports" to "missing"))[DoctorCheckID.PORTS_SKILL]?.fix)
        assertEquals(DoctorFix.InstallPortsSkill(isUpdate = true), evaluate(mapOf("skill.ports" to "outdated"))[DoctorCheckID.PORTS_SKILL]?.fix)
        assertNull(evaluate()[DoctorCheckID.PORTS_SKILL]?.fix)
    }

    @Test
    fun `projects json ausente es normal e invalido es un problema`() {
        assertEquals(DoctorStatus.OK, status(DoctorCheckID.PROJECTS_FILE, mapOf("projects.file" to "missing")))
        assertEquals(DoctorStatus.PROBLEM, status(DoctorCheckID.PROJECTS_FILE, mapOf("projects.json" to "invalid")))
        assertEquals(DoctorStatus.PROBLEM, status(DoctorCheckID.PROJECTS_FILE, mapOf("projects.file" to "unreadable")))
        assertTrue(evaluate()[DoctorCheckID.PROJECTS_FILE]?.detail?.contains("versión 1") == true)
    }

    @Test
    fun `locale sin UTF-8 es un aviso con arreglo`() {
        assertEquals(DoctorStatus.WARNING, status(DoctorCheckID.LOCALE, mapOf("locale.env" to "no", "locale.avail" to "yes")))
        assertNotNull(evaluate(mapOf("locale.env" to "no", "locale.avail" to "no"))[DoctorCheckID.LOCALE]?.fix)
        assertEquals(DoctorStatus.WARNING, status(DoctorCheckID.LOCALE, mapOf("locale.env" to "no", "locale.avail" to "unknown")))
        assertEquals(DoctorStatus.UNKNOWN, evaluate(removing = setOf("locale.env"))[DoctorCheckID.LOCALE]?.status)
    }

    @Test
    fun `reloj avisa desde 1 min y da problema desde 5 en ambos sentidos`() {
        assertEquals(DoctorStatus.OK, evaluate(skewSeconds = 5)[DoctorCheckID.CLOCK]?.status)
        assertEquals(DoctorStatus.WARNING, evaluate(skewSeconds = 90)[DoctorCheckID.CLOCK]?.status)
        assertEquals(DoctorStatus.WARNING, evaluate(skewSeconds = -90)[DoctorCheckID.CLOCK]?.status)
        assertEquals(DoctorStatus.PROBLEM, evaluate(skewSeconds = 400)[DoctorCheckID.CLOCK]?.status)
        assertEquals(DoctorStatus.UNKNOWN, status(DoctorCheckID.CLOCK, mapOf("clock" to "x")))
    }

    @Test
    fun `el resumen cuenta problemas y avisos`() {
        val checks = listOf(
            DoctorCheck(DoctorCheckID.TMUX, "a", DoctorStatus.PROBLEM, ""),
            DoctorCheck(DoctorCheckID.GIT, "b", DoctorStatus.WARNING, ""),
            DoctorCheck(DoctorCheckID.GH, "c", DoctorStatus.WARNING, ""),
            DoctorCheck(DoctorCheckID.CLAUDE, "d", DoctorStatus.UNKNOWN, ""),
        )
        val result = DoctorResult(checks, Instant.EPOCH)
        assertEquals("1 problema y 2 avisos.", result.summary)
        assertEquals(DoctorStatus.PROBLEM, result.overall)
        assertTrue(result.plainText("servidor-1").contains("[Aviso] b"))
    }

    @Test
    fun `los tamanos se escriben con punto decimal`() {
        assertEquals("1.5 GB", DoctorSystemRules.formatKB(1_572_864))
        assertEquals("200 MB", DoctorSystemRules.formatKB(204_800))
        assertEquals("90 s", DoctorSystemRules.formatSeconds(89.6))
        assertEquals("2 min", DoctorSystemRules.formatSeconds(100.0))
    }
}
