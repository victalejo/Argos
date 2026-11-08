package com.iaportafolio.argos.core.tmux

import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Paridad con `ArgosTests/WindowManagementTests.swift` (contrato del comando exacto que se envía
 * al servidor), más los comandos de sesión y de entorno de `SSHService.swift`.
 */
class WindowManagementTest {

    @Test
    fun `nueva ventana hereda el directorio del panel activo`() {
        assertEquals("tmux new-window -t 'roomies' -c '#{pane_current_path}'", TmuxCommands.newWindow("roomies"))
    }

    @Test
    fun `renombrar apunta a sesion e indice y entrecomilla el nombre`() {
        assertEquals("tmux rename-window -t 'a b':2 'it'\\''s'", TmuxCommands.renameWindow("a b", 2, "it's"))
    }

    @Test
    fun `cerrar ventana apunta a sesion e indice`() {
        assertEquals("tmux kill-window -t 'a b':3", TmuxCommands.killWindow("a b", 3))
    }

    @Test
    fun `fijar color guarda la opcion de usuario argos_color`() {
        assertEquals("tmux set-option -w -t 'dev':1 @argos_color 'green'", TmuxCommands.windowColor("dev", 1, WindowColor.GREEN))
    }

    @Test
    fun `quitar color borra la opcion`() {
        assertEquals("tmux set-option -wu -t 'dev':1 @argos_color", TmuxCommands.windowColor("dev", 1, null))
    }

    @Test
    fun `el formato de list-windows lleva el nombre al final`() {
        assertTrue(TmuxCommands.LIST_WINDOWS_FORMAT.endsWith("|#{window_name}"))
        assertTrue("#{@argos_color}" in TmuxCommands.LIST_WINDOWS_FORMAT)
    }

    @Test
    fun `el formato de list-windows incluye el proceso en primer plano`() {
        assertTrue("|#{pane_current_command}|" in TmuxCommands.LIST_WINDOWS_FORMAT)
    }

    @Test
    fun `ventana con agente usa nombre fijo, carpeta del proyecto y teclea el binario`() {
        assertEquals(
            "idx=\$(tmux new-window -P -F '#{window_index}' -t 'roomies' -c '/srv/it'\\''s' " +
                "-n 'Claude Code') && tmux send-keys -t 'roomies':\"\$idx\" 'claude' Enter",
            TmuxCommands.newAgentWindow("roomies", CodingAgent.CLAUDE, "/srv/it's"),
        )
    }

    @Test
    fun `ventana con agente sin carpeta usa la del panel activo`() {
        val command = TmuxCommands.newAgentWindow("dev", CodingAgent.CODEX, null)
        assertTrue("-c '#{pane_current_path}'" in command)
        assertTrue("-n 'Codex'" in command)
        assertTrue(command.endsWith("'codex' Enter"))
    }

    @Test
    fun `rama git entrecomilla la ruta`() {
        assertEquals("git -C '/srv/a b' rev-parse --abbrev-ref HEAD 2>/dev/null", TmuxCommands.gitBranch("/srv/a b"))
    }

    @ParameterizedTest
    @ValueSource(strings = ["claude", "api: logs", "v1.2", "a|b"])
    fun `nombres de ventana validos`(name: String) {
        assertTrue(WindowNameValidator.isValid(name))
    }

    @ParameterizedTest
    @ValueSource(strings = ["", "   ", "-x", "a\nb", "a\tb"])
    fun `nombres de ventana invalidos`(name: String) {
        assertFalse(WindowNameValidator.isValid(name))
    }

    @Test
    fun `todos los colores se identifican por su rawValue`() {
        WindowColor.entries.forEach { assertEquals(it, WindowColor.fromRawValue(it.rawValue)) }
    }

    @Test
    fun `rama git es la ultima linea y HEAD desacoplado o vacio da null`() {
        assertEquals("feat/x", TmuxOutputParser.parseGitBranch("motd\nfeat/x\n"))
        assertNull(TmuxOutputParser.parseGitBranch("HEAD\n"))
        assertNull(TmuxOutputParser.parseGitBranch(""))
        assertNull(TmuxOutputParser.parseGitBranch("main\n", exitCode = 128))
    }

    @Test
    fun `comandos de sesion identicos a Apple`() {
        assertEquals("tmux list-sessions -F '#{session_name}|#{session_windows}|#{session_attached}|#{session_created}'", TmuxCommands.LIST_SESSIONS)
        assertEquals("tmux new-session -d -s 'a b'", TmuxCommands.createSession("a b"))
        assertEquals("tmux rename-session -t '=old' 'new'", TmuxCommands.renameSession("old", "new"))
        assertEquals("tmux kill-session -t '=it'\\''s'", TmuxCommands.killSession("it's"))
        assertEquals("tmux attach -t 'main'", TmuxCommands.attach("main"))
        assertEquals("tmux select-window -t 'main':4", TmuxCommands.selectWindow("main", 4))
        assertEquals(
            "tmux list-windows -t 'main' -F '#{window_index}|#{window_active}|#{window_panes}|#{@argos_color}|#{pane_current_command}|#{window_name}'",
            TmuxCommands.listWindows("main"),
        )
    }

    @Test
    fun `comandos de entorno identicos a Apple`() {
        assertEquals("command -v tmux", TmuxCommands.IS_TMUX_INSTALLED)
        assertEquals("sudo -n true", TmuxCommands.CAN_USE_SUDO_NON_INTERACTIVE)
        assertEquals("test -f \"\$HOME/.tmux.conf\"", TmuxCommands.TMUX_CONFIG_EXISTS)
        assertTrue(TmuxCommands.WRITE_DEFAULT_TMUX_CONFIG.startsWith("if [ ! -f \"\$HOME/.tmux.conf\" ]; then\n"))
        assertTrue(TmuxCommands.WRITE_DEFAULT_TMUX_CONFIG.endsWith("\nARGOS_TMUX_CONF\nfi"))
        assertTrue("set -ga terminal-overrides \",*:Ms=\\\\E]52;%p1%s;%p2%s\\\\007\"" in TmuxCommands.DEFAULT_TMUX_CONFIG)
        assertTrue("',*:Ms=\\E]52;%p1%s;%p2%s\\007'" in TmuxCommands.ENABLE_CLIPBOARD_FORWARDING)
    }

    /** El heredoc de `~/.tmux.conf` es sh válido (se comprueba con `sh -n`). */
    @Test
    fun `el comando de tmux conf es sh valido`() {
        val process = ProcessBuilder("/bin/sh", "-n", "-c", TmuxCommands.WRITE_DEFAULT_TMUX_CONFIG)
            .redirectErrorStream(true)
            .start()
        val output = process.inputStream.bufferedReader().readText()
        assertEquals(0, process.waitFor(), output)
    }
}
