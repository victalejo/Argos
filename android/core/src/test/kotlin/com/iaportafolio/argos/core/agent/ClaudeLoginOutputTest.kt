package com.iaportafolio.argos.core.agent

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Paridad con `ArgosTests/ClaudeLoginOutputTests.swift` (salida REAL con hipervínculo OSC 8). */
class ClaudeLoginOutputTest {

    private val url = "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a&response_type=code&state=abc"

    private val realOutput = "Opening browser to sign in…\r\n" +
        "If the browser didn't open, visit: \u001B]8;;$url\u0007$url\u001B]8;;\u0007\r\n" +
        "Paste code here if prompted > "

    @Test
    fun `detecta el enlace de autorizacion y que pide el codigo`() {
        val output = ClaudeLoginOutput.parse(realOutput)
        assertEquals(url, output.authorizationURL?.toString())
        assertTrue(output.isAwaitingCode)
    }

    @Test
    fun `salida parcial aun sin enlace ni peticion de codigo`() {
        val output = ClaudeLoginOutput.parse("Opening browser to sign in…\r\n")
        assertNull(output.authorizationURL)
        assertFalse(output.isAwaitingCode)
    }

    @Test
    fun `quita OSC, CSI y retornos de carro`() {
        val raw = "\u001B[1mHola\u001B[0m\r\n\u001B]0;titulo\u0007mundo \u001B]8;;https://x\u001B\\enlace"
        assertEquals("Hola\nmundo enlace", ClaudeLoginOutput.stripEscapes(raw))
    }

    @Test
    fun `ignora enlaces OAuth de dominios que no son de Anthropic`() {
        val evil = "visit: https://claude.com.evil.io/oauth/authorize?x=1 or https://evil.com/oauth"
        assertNull(ClaudeLoginOutput.parse(evil).authorizationURL)
        val sub = "visit: https://login.claude.ai/oauth/authorize?x=1"
        assertEquals("login.claude.ai", ClaudeLoginOutput.parse(sub).authorizationURL?.host)
    }
}
