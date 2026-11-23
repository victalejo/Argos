package com.iaportafolio.argos.core.projects

import com.iaportafolio.argos.core.Server
import kotlin.test.Test
import kotlin.test.assertEquals

/** Comandos remotos y textos de confirmación: idénticos a los de Apple. */
class ProjectCommandsTest {

    @Test
    fun `arrancar un proyecto con comando teclea el arranque en la sesion exacta`() {
        assertEquals(
            "[ -d '/srv/it'\\''s' ] || exit 3; tmux has-session -t '=ia/coro' 2>/dev/null && exit 0; " +
                "tmux new-session -d -s 'ia/coro' -c '/srv/it'\\''s' " +
                "&& tmux send-keys -t '=ia/coro:' 'cc --continue' Enter",
            ProjectCommands.startProject("ia/coro", "/srv/it's", "cc --continue"),
        )
    }

    @Test
    fun `arrancar es idempotente - si la sesion exacta existe sale con 0 sin crear nada`() {
        assertEquals(
            "[ -d '/srv/web' ] || exit 3; tmux has-session -t '=tmh/web' 2>/dev/null && exit 0; " +
                "tmux new-session -d -s 'tmh/web' -c '/srv/web' && tmux send-keys -t '=tmh/web:' 'cc --continue' Enter",
            ProjectCommands.startProject("tmh/web", "/srv/web", "cc --continue"),
        )
    }

    @Test
    fun `rutas y comandos fijos coinciden con Apple`() {
        assertEquals(".config/argos/projects.json", ProjectCommands.PROJECTS_RELATIVE_PATH)
        assertEquals(
            "tmux -u list-panes -a -F '#{window_index}|#{pane_index}|#{pane_current_path}|#{session_name}' 2>/dev/null",
            ProjectCommands.FIRST_PANE_PATHS,
        )
        assertEquals("No se pudo detener la sesión 'x'.", ProjectCommands.stopSessionFailureMessage("x"))
    }

    @Test
    fun `confirmaciones con ids y textos de Apple`() {
        val server = Server(id = "S1", name = "dev", host = "h", username = "u")
        val coro = Project(id = "P1", name = "coro", path = "/c")
        val web = Project(id = "P2", name = "web", path = "/w")

        val stop = ProjectConfirmation.Stop(server, coro)
        assertEquals("stop-P1", stop.id)
        assertEquals("¿Detener 'coro'?", stop.title)
        assertEquals("Detener", stop.actionLabel)
        assertEquals(server, stop.server)

        val remove = ProjectConfirmation.Remove(server, coro)
        assertEquals("remove-P1", remove.id)
        assertEquals("¿Quitar el proyecto 'coro'?", remove.title)
        assertEquals("Quitar", remove.actionLabel)

        val background = ProjectConfirmation.StopBackground(server, listOf(web, coro))
        assertEquals("stop-bg-S1", background.id)
        assertEquals("¿Detener 2 proyectos en segundo plano?", background.title)
        assertEquals(
            "coro, web\n\nSe cerrarán sus sesiones para liberar memoria; los proyectos se conservan.",
            background.message,
        )
        assertEquals("¿Detener 1 proyecto en segundo plano?", ProjectConfirmation.StopBackground(server, listOf(web)).title)
    }
}
