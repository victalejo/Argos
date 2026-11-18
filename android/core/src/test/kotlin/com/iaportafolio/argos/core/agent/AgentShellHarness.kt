package com.iaportafolio.argos.core.agent

import com.iaportafolio.argos.core.ShellQuoting
import java.io.File
import java.nio.file.Files
import java.time.Instant

/**
 * Banco de pruebas para EJECUTAR de verdad los scripts del agente persistente (como
 * `AgentHardeningShellTests.swift`): un HOME temporal con `bin/` delante del PATH, donde `sh` es
 * el shell probado (también para los `sh -c` internos), y un «claude» simulado.
 */
class AgentShellHarness(val shell: String, setsid: Boolean = false) : AutoCloseable {

    val id = "6a55640d-ac70-41ab-8426-6eb72d4fb5eb"
    val home: File = Files.createTempDirectory("argos-hard-").toFile()
    val agentDir: File get() = File(home, ".config/argos/agents/$id")

    data class Run(val status: Int, val output: String)

    init {
        val bin = File(home, "bin").apply { mkdirs() }
        Files.createSymbolicLink(File(bin, "sh").toPath(), File(shell).toPath())
        if (setsid && !hasCommand("setsid")) {
            File(bin, "setsid").apply {
                writeText("#!/bin/sh\nexec /usr/bin/perl -e 'setpgrp(0,0); exec @ARGV or die' \"\$@\"\n")
                setExecutable(true)
            }
        }
    }

    val path: String get() = "${home.path}/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    fun sh(command: String, stdin: ByteArray? = null): Run {
        val builder = ProcessBuilder(shell, "-c", command).redirectError(ProcessBuilder.Redirect.DISCARD)
        builder.environment().apply {
            clear()
            put("HOME", home.path)
            put("PATH", path)
        }
        val process = builder.start()
        process.outputStream.use { out -> stdin?.let(out::write) }
        val output = process.inputStream.readBytes().toString(Charsets.UTF_8)
        return Run(process.waitFor(), output)
    }

    /**
     * «claude» falso: por cada línea de la FIFO responde (con `permiso`, pide un permiso; si no,
     * cierra el turno con un `result`). [ignoreTerm]: no muere con TERM. [child]: deja un hijo
     * `sleep` cuyo PID anota. [deaf]: nunca lee la FIFO. [failing]: muere al arrancar.
     */
    fun fakeClaude(ignoreTerm: Boolean = false, child: Boolean = false, deaf: Boolean = false, failing: Boolean = false): String {
        val fake = File(home, "claude-falso.sh")
        val lines = mutableListOf("#!/bin/sh")
        if (failing) {
            lines += listOf("echo 'error: unknown option --foo' >&2", "exit 1")
        } else {
            if (ignoreTerm) lines += "trap '' TERM"
            if (child) lines += "sleep 300 & echo \$! > \"\$HOME/child.pid\""
            if (deaf) {
                lines += "while true; do sleep 1; done"
            } else {
                lines += listOf(
                    "while IFS= read -r line; do",
                    "  case \"\$line\" in",
                    "    *permiso*) printf '%s\\n' '{\"type\":\"control_request\",\"request_id\":\"r1\",\"request\":" +
                        "{\"subtype\":\"can_use_tool\",\"tool_name\":\"Bash\",\"input\":{}}}' ;;",
                    "    *) printf '{\"type\":\"echo\",\"bytes\":%s}\\n' \"\${#line}\"; printf '%s\\n' " +
                        "'{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"ok\"}' ;;",
                    "  esac",
                    "done",
                )
            }
        }
        fake.writeText(lines.joinToString("\n") + "\n")
        fake.setExecutable(true)
        return "${ShellQuoting.singleQuoted(fake.path)} --session-id $id"
    }

    fun meta(): PersistentAgentMeta = PersistentAgentMeta(home.path, "t", Instant.ofEpochSecond(1_800_000_000))

    fun launch(invocation: String, hibernation: PersistentAgentHibernation = PersistentAgentHibernation.ofHours(0)): Run =
        sh(PersistentAgentScript.launch(id, meta(), invocation, hibernation), "\n".toByteArray())

    /** Lo que lleva escrito el log del agente (vacío si aún no existe). */
    fun logText(): String = runCatching { File(agentDir, "out.ndjson").readText() }.getOrDefault("")

    fun listed(): PersistentAgentInfo? = PersistentAgentScript.parseList(sh(PersistentAgentScript.list()).output).firstOrNull()

    fun writeMeta(meta: PersistentAgentMeta = meta()) {
        agentDir.mkdirs()
        File(agentDir, "meta.json").writeText(PersistentAgentMeta.encode(meta))
    }

    override fun close() {
        // Que no quede ningún proceso del agente vivo entre pruebas.
        runCatching { sh(PersistentAgentScript.stop(id, delete = false, graceSeconds = 1)) }
        home.deleteRecursively()
    }

    companion object {
        /** Shells disponibles: `/bin/sh` (dash en Debian/Ubuntu) y dash/bash explícitos. */
        @JvmStatic
        fun shells(): List<String> = listOf("/bin/sh", "/bin/dash", "/bin/bash").filter { File(it).canExecute() }

        fun waitUntil(seconds: Double, condition: () -> Boolean): Boolean {
            val deadline = System.nanoTime() + (seconds * 1e9).toLong()
            while (System.nanoTime() < deadline) {
                if (condition()) return true
                Thread.sleep(100)
            }
            return condition()
        }

        fun isRunning(pid: Long): Boolean = ProcessHandle.of(pid).map { it.isAlive }.orElse(false)

        fun processGroup(pid: Long): Long? =
            ProcessBuilder("ps", "-o", "pgid=", "-p", pid.toString()).start().inputStream.readBytes()
                .toString(Charsets.UTF_8).trim().toLongOrNull()

        private fun hasCommand(name: String): Boolean =
            listOf("/usr/bin", "/bin", "/usr/sbin", "/sbin").any { File(it, name).canExecute() }
    }
}
