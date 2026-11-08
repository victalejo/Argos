package com.iaportafolio.argos.core

import kotlin.test.Test
import kotlin.test.assertEquals

/** Paridad con `ArgosTests/SessionConnectionStateTests.swift`. */
class SessionConnectionStateTest {

    private fun from(status: LiveTerminalStatus?, attached: Boolean) = SessionConnectionState.from(status, attached)

    @Test
    fun `conectando da connecting independiente de isAttached`() {
        assertEquals(SessionConnectionState.CONNECTING, from(LiveTerminalStatus.Connecting, false))
        assertEquals(SessionConnectionState.CONNECTING, from(LiveTerminalStatus.Connecting, true))
    }

    @Test
    fun `conectado da live`() {
        assertEquals(SessionConnectionState.LIVE, from(LiveTerminalStatus.Connected, false))
    }

    @Test
    fun `fallo da error`() {
        assertEquals(SessionConnectionState.ERROR, from(LiveTerminalStatus.Failed("boom"), true))
    }

    @Test
    fun `sin terminal cargado y sin adjuntar da dormant`() {
        assertEquals(SessionConnectionState.DORMANT, from(null, false))
    }

    @Test
    fun `sin terminal cargado pero adjunta en tmux da attachedElsewhere`() {
        assertEquals(SessionConnectionState.ATTACHED_ELSEWHERE, from(null, true))
    }

    @Test
    fun `detach limpio da dormant o attachedElsewhere segun tmux`() {
        assertEquals(SessionConnectionState.DORMANT, from(LiveTerminalStatus.Ended, false))
        assertEquals(SessionConnectionState.ATTACHED_ELSEWHERE, from(LiveTerminalStatus.Ended, true))
    }
}
