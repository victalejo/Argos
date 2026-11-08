package com.iaportafolio.argos.ssh.testing

import com.pty4j.PtyProcess
import com.pty4j.PtyProcessBuilder
import com.pty4j.WinSize
import org.apache.sshd.server.Environment
import org.apache.sshd.server.ExitCallback
import org.apache.sshd.server.Signal
import org.apache.sshd.server.channel.ChannelSession
import org.apache.sshd.server.command.Command
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Path
import java.util.concurrent.TimeUnit

/**
 * Ejecuta un comando SSH en la máquina local con `<loginShell> -c`, como haría `sshd` con el shell
 * del usuario, pero con un ENTORNO CONTROLADO ([environment]: `HOME`, `TMUX_TMPDIR`, `PATH`…)
 * para no tocar el `$HOME` ni las sesiones tmux reales de quien corre los tests.
 *
 * Si el cliente pidió PTY (terminal en vivo, fase 3) el proceso corre en un PTY REAL de pty4j
 * (macOS y Linux) con el tamaño del `pty-req`, y cada `window-change` del cliente se propaga
 * con `setWinSize` (el proceso recibe SIGWINCH, como con OpenSSH): tmux ve el tamaño nuevo.
 *
 * `command == null` = shell interactivo (`ssh` sin comando).
 */
internal class LocalShellCommand(
    private val command: String?,
    private val environment: Map<String, String>,
    private val workingDirectory: Path,
    private val loginShell: String = "/bin/sh",
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
        val term = env.env[Environment.ENV_TERM]
        val hasPty = env.ptyModes.isNotEmpty() || term != null
        val processEnvironment = term?.let { environment + (Environment.ENV_TERM to it) } ?: environment
        val started = if (hasPty) startPty(env, processEnvironment) else startPlain(processEnvironment)
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

    /**
     * Con PTY (OpenSSH manda SIGHUP) se mata. Sin PTY, sshd solo cierra las tuberías: el proceso ve
     * EOF en stdin y termina por su cuenta, ejecutando sus `trap` (cerrojo del lanzador del agente,
     * `tail` de un enganche). Un SIGKILL inmediato los dejaría huérfanos, algo que en un servidor
     * real no pasa. Solo se fuerza si tras un margen sigue vivo.
     */
    override fun destroy(channel: ChannelSession) {
        val running = process ?: return
        if (running is PtyProcess) {
            running.destroyForcibly()
            return
        }
        try {
            running.outputStream.close()
        } catch (_: IOException) {
            // Ya estaba cerrado: el proceso ya vio el EOF.
        }
        daemon("reap") {
            if (!running.waitFor(EOF_GRACE_SECONDS, TimeUnit.SECONDS)) {
                running.destroy()
                if (!running.waitFor(TERM_GRACE_SECONDS, TimeUnit.SECONDS)) running.destroyForcibly()
            }
        }
    }

    private fun startPlain(processEnvironment: Map<String, String>): Process {
        val builder = ProcessBuilder(loginShell, "-c", script()).directory(workingDirectory.toFile())
        builder.environment().clear()
        builder.environment().putAll(processEnvironment)
        return builder.start()
    }

    /** PTY real con el tamaño pedido; `window-change` → [PtyProcess.setWinSize]. */
    private fun startPty(env: Environment, processEnvironment: Map<String, String>): PtyProcess {
        val pty = PtyProcessBuilder(arrayOf(loginShell, "-c", script()))
            .setEnvironment(processEnvironment)
            .setDirectory(workingDirectory.toString())
            .setInitialColumns(env.dimension(Environment.ENV_COLUMNS) ?: DEFAULT_COLUMNS)
            .setInitialRows(env.dimension(Environment.ENV_LINES) ?: DEFAULT_ROWS)
            .setRedirectErrorStream(true)
            .setConsole(false)
            .start()
        env.addSignalListener({ _, _ ->
            val columns = env.dimension(Environment.ENV_COLUMNS)
            val rows = env.dimension(Environment.ENV_LINES)
            if (columns != null && rows != null && pty.isAlive) pty.winSize = WinSize(columns, rows)
        }, Signal.WINCH)
        return pty
    }

    private fun script(): String = command ?: "exec /bin/sh -i"

    private fun Environment.dimension(key: String): Int? = env[key]?.toIntOrNull()?.takeIf { it > 0 }

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
        val buffer = ByteArray(BUFFER_SIZE)
        try {
            to.use { stdin ->
                // Con flush en cada bloque: la tubería del proceso va con búfer y un lanzador que
                // espera UNA línea por stdin (el token) se quedaría esperando para siempre.
                while (true) {
                    val read = from.read(buffer)
                    if (read < 0) break
                    stdin.write(buffer, 0, read)
                    stdin.flush()
                }
            }
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
        const val DEFAULT_COLUMNS = 80
        const val DEFAULT_ROWS = 24
        const val EOF_GRACE_SECONDS = 3L
        const val TERM_GRACE_SECONDS = 1L
    }
}
