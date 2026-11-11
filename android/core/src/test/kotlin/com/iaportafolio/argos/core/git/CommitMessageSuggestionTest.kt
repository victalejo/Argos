package com.iaportafolio.argos.core.git

import com.iaportafolio.argos.core.agent.AgentExecStreaming
import com.iaportafolio.argos.core.agent.ClaudeAuthStatus
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** Mensaje de commit sugerido (paridad con `ArgosTests/CommitMessageTests.swift`). */
class CommitMessageSuggestionTest {

    private fun golden(name: String): String =
        assertNotNull(javaClass.getResource("/swift-golden/$name.txt"), "falta $name").readText(Charsets.UTF_8)

    private val mod = GitFileChange("src/a b.swift", null, ' ', 'M')
    private val ren = GitFileChange("nuevo.txt", "viejo*.txt", 'R', ' ')
    private val unt = GitFileChange("it's new.txt", null, '?', '?')

    @Test
    fun `comando idéntico a Swift`() {
        assertEquals(
            golden("cm-suggest"),
            CommitMessageSuggestion.command("/home/u/.local/bin/claude", "/home/u/mi repo's", listOf(mod, ren, unt), true),
        )
        assertEquals(
            golden("cm-suggest-nocommits"),
            CommitMessageSuggestion.command("/usr/bin/claude", "/srv/app", listOf(mod, unt), false),
        )
        assertEquals(
            golden("cm-suggest-untracked"),
            CommitMessageSuggestion.command("/usr/bin/claude", "/srv/app", listOf(unt), true),
        )
    }

    @Test
    fun `el token va por stdin y nunca se usa la API`() {
        val command = CommitMessageSuggestion.command("/c", "/r", listOf(mod), true)
        assertTrue("read -r ARGOS_OAUTH" in command)
        assertTrue("env -u ANTHROPIC_API_KEY" in command)
        assertFalse("CLAUDE_CODE_OAUTH_TOKEN=sk" in command)
    }

    @Test
    fun `limpia bloques de código, comillas y prefijos`() {
        assertEquals("feat: x", CommitMessageSuggestion.clean("```\nfeat: x\n```"))
        assertEquals("fix: y", CommitMessageSuggestion.clean("Mensaje de commit: \"fix: y\""))
        assertEquals("docs: z", CommitMessageSuggestion.clean("«docs: z»"))
        assertEquals("feat: a\n\ncuerpo", CommitMessageSuggestion.clean("Commit message:\nfeat: a\n\ncuerpo"))
    }

    @Test
    fun `código de salida - el mensaje o el error de claude`() {
        assertEquals("feat: x", CommitMessageSuggestion.parse("feat: x\n\nARGOS_CM_EXIT:0\n"))
        val error = assertFailsWith<GitCommandException> {
            CommitMessageSuggestion.parse("Not logged in\nARGOS_CM_EXIT:1\n")
        }
        assertEquals("Not logged in", error.message)
        assertEquals(
            "claude terminó con código 127.",
            assertFailsWith<GitCommandException> { CommitMessageSuggestion.parse("ARGOS_CM_EXIT:127") }.message,
        )
        assertEquals(
            CommitMessageSuggestion.NO_RESPONSE,
            assertFailsWith<GitCommandException> { CommitMessageSuggestion.parse("feat: a medias") }.message,
        )
        assertEquals(
            CommitMessageSuggestion.EMPTY,
            assertFailsWith<GitCommandException> { CommitMessageSuggestion.parse("```\n```\nARGOS_CM_EXIT:0") }.message,
        )
    }

    private class FakeExec(private val lines: List<String>) : AgentExecStreaming {
        var command: String? = null
        var firstStdin: String? = null

        override suspend fun runAgentExec(command: String, stdin: Flow<ByteArray>, output: suspend (ByteArray) -> Unit) {
            this.command = command
            firstStdin = stdin.first().decodeToString()
            lines.forEach { output((it + "\n").encodeToByteArray()) }
        }

        override suspend fun claudeAuthStatus(): ClaudeAuthStatus? = null
    }

    @Test
    fun `pide la sugerencia con el token por stdin`(): Unit = runBlocking {
        val exec = FakeExec(listOf("```", "feat: amplía a", "```", "ARGOS_CM_EXIT:0"))
        val message = CommitMessageSuggestion.suggest({ "/c" }, exec, "/r", listOf(mod), true, "tok")
        assertEquals("feat: amplía a", message)
        assertEquals("tok\n", exec.firstStdin)
        assertTrue("'src/a b.swift'" in exec.command.orEmpty())
    }

    @Test
    fun `sin claude en el servidor avisa`(): Unit = runBlocking {
        val error = assertFailsWith<GitCommandException> {
            CommitMessageSuggestion.suggest({ null }, FakeExec(emptyList()), "/r", listOf(mod), true, null)
        }
        assertEquals(CommitMessageSuggestion.CLAUDE_MISSING, error.message)
    }
}
