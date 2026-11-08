package com.iaportafolio.argos.ssh.testing

import org.apache.sshd.server.Environment
import org.apache.sshd.server.ExitCallback
import org.apache.sshd.server.channel.ChannelSession
import org.apache.sshd.server.command.Command
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Path

/**
 * Ejecuta un comando SSH en la máquina local con `/bin/sh -c`, como haría `sshd` con el shell
 * del usuario, pero con un ENTORNO CONTROLADO ([environment]: `HOME`, `TMUX_TMPDIR`, `PATH`…)
 * para no tocar el `$HOME` ni las sesiones tmux reales de quien corre los tests.
 *
 * Si el cliente pidió PTY (terminal en vivo, fase 3) se envuelve en `script(1)` para que el
 * proceso tenga un terminal real (`tmux attach` lo exige). El redimensionado no se propaga.
 *
 * `command == null` = shell interactivo (`ssh` sin comando).
 */
internal class LocalShellCommand(
    private val command: String?,
    private val environment: Map<String, String>,
    private val workingDirectory: Path,
) : Command {
    private var stdin: InputStream? = null
    private var stdout: OutputStream? = null
    private var stderr: OutputStream? = null
    private var exitCallback: ExitCallback? = null

    @Volatile
    private var process: Process? = null

    override fun setInputStream(input: InputStream) {
        stdin = input
    }

    override fun setOutputStream(output: OutputStream) {
        stdout = output
    }

    override fun setErrorStream(error: OutputStream) {
        stderr = error
    }

    override fun setExitCallback(callback: ExitCallback) {
        exitCallback = callback
    }

    override fun start(channel: ChannelSession, env: Environment) {
        val input = checkNotNull(stdin) { "stdin sin asignar" }
        val output = checkNotNull(stdout) { "stdout sin asignar" }
        val error = checkNotNull(stderr) { "stderr sin asignar" }
        val callback = checkNotNull(exitCallback) { "exitCallback sin asignar" }
        val term = env.env["TERM"]
        val hasPty = env.ptyModes.isNotEmpty() || term != null

        val builder = ProcessBuilder(argv(hasPty, env)).directory(workingDirectory.toFile())
        builder.environment().clear()
        builder.environment().putAll(environment)
        term?.let { builder.environment()["TERM"] = it }
        val started = builder.start()
        process = started

        val outPump = pump("out", started.inputStream, output)
        val errPump = pump("err", started.errorStream, error)
        daemon("in") { copyStdin(input, started.outputStream) }
        daemon("wait") {
            val code = started.waitFor()
            outPump.join()
            errPump.join()
            callback.onExit(code)
        }
    }

    override fun destroy(channel: ChannelSession) {
        process?.destroyForcibly()
    }

    private fun argv(hasPty: Boolean, env: Environment): List<String> {
        val script = command ?: "exec /bin/sh -i"
        if (!hasPty) return listOf("/bin/sh", "-c", script)
        val columns = env.env[Environment.ENV_COLUMNS]
        val lines = env.env[Environment.ENV_LINES]
        val sized = if (columns != null && lines != null) "stty cols $columns rows $lines 2>/dev/null; $script" else script
        val isMac = System.getProperty("os.name").startsWith("Mac")
        return if (isMac) {
            listOf("/usr/bin/script", "-q", "/dev/null", "/bin/sh", "-c", sized)
        } else {
            listOf("/usr/bin/script", "-qfec", sized, "/dev/null")
        }
    }

    private fun pump(name: String, from: InputStream, to: OutputStream): Thread = daemon(name) {
        val buffer = ByteArray(BUFFER_SIZE)
        try {
            while (true) {
                val read = from.read(buffer)
                if (read < 0) break
                to.write(buffer, 0, read)
                to.flush()
            }
        } catch (_: IOException) {
            // El canal se cerró (cliente desconectado): el proceso termina por su cuenta.
        }
    }

    private fun copyStdin(from: InputStream, to: OutputStream) {
        try {
            to.use { from.copyTo(it) }
        } catch (_: IOException) {
            // EOF/cierre del canal o el proceso ya terminó.
        }
    }

    private fun daemon(name: String, body: () -> Unit): Thread =
        Thread(body, "local-shell-$name").apply {
            isDaemon = true
            start()
        }

    private companion object {
        const val BUFFER_SIZE = 8 * 1024
    }
}
