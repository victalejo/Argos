package com.iaportafolio.argos.core.git

import com.iaportafolio.argos.core.ShellQuoting
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Panel «Cambios» y resumen git (paridad con `ArgosTests/GitTests.swift` y `GitSummaryTests.swift`):
 * parsers, comandos remotos byte a byte con Swift y textos.
 */
class GitParityGoldenTest {

    private fun golden(name: String): String =
        assertNotNull(javaClass.getResource("/swift-golden/$name.txt"), "falta $name").readText(Charsets.UTF_8)

    private fun assertGolden(name: String, actual: String) = assertEquals(golden(name), actual, "difiere de Swift: $name")

    private val root = "/home/u/mi repo's"
    private val mod = GitFileChange("src/a b.swift", null, ' ', 'M')
    private val ren = GitFileChange("nuevo.txt", "viejo*.txt", 'R', ' ')
    private val unt = GitFileChange("*", null, '?', '?')

    @Test
    fun `comandos git idénticos a Swift`() {
        assertGolden("git-status", GitCommands.status("~/p/\$(x)"))
        assertGolden("git-diff-modified", GitCommands.diff(root, mod, hasCommits = true))
        assertGolden("git-diff-renamed", GitCommands.diff(root, ren, hasCommits = true))
        assertGolden("git-diff-untracked", GitCommands.diff(root, unt, hasCommits = true))
        assertGolden("git-diff-nocommits", GitCommands.diff(root, mod, hasCommits = false))
        assertGolden("git-discard-tracked", GitCommands.discard(root, ren))
        assertGolden("git-discard-untracked", GitCommands.discard(root, unt))
        assertGolden("git-commit", GitCommands.commit(root, "feat: «hola» 'x' \$HOME\nsegunda", listOf(mod, ren, unt)))
        assertGolden("git-push-upstream", GitCommands.push(root, hasUpstream = true))
        assertGolden("git-push-new", GitCommands.push(root, hasUpstream = false))
        assertGolden("git-pull", GitCommands.pull(root))
        assertGolden("git-summaries", GitSummaryCommands.summaries(listOf("/a", "~/b c", "/d'e")))
    }

    @Test
    fun `aviso de Claude idéntico a Swift`() {
        assertGolden("claude-done-0", ClaudeDoneMessage.body(0))
        assertGolden("claude-done-1", ClaudeDoneMessage.body(1))
        assertGolden("claude-done-5", ClaudeDoneMessage.body(5))
        assertEquals("Terminó de responder.", ClaudeDoneMessage.body(null))
    }
}

class GitStatusParserTest {

    private fun output(porcelain: String, root: String = "/home/dev/app") =
        "motd ruidoso\n${GitCommands.ROOT_MARKER}$root\n$porcelain"

    private fun repository(output: String) = assertIs<GitStatusResult.Repository>(GitStatusParser.parse(output)).status

    @Test
    fun `sin marcador es carpeta sin repositorio y detecta git ausente`() {
        assertEquals(GitStatusResult.NotRepository, GitStatusParser.parse(""))
        assertEquals(GitStatusResult.NotRepository, GitStatusParser.parse("algo del perfil\n"))
        assertEquals(GitStatusResult.GitMissing, GitStatusParser.parse("${GitCommands.NO_GIT_MARKER}\n"))
    }

    @Test
    fun `parsea rama, upstream, ahead-behind y entradas`() {
        val porcelain = "## main...origin/main [ahead 2, behind 1]\u0000 M src/a.swift\u0000" +
            "A  nuevo.txt\u0000R  b2.swift\u0000b.swift\u0000?? notas/x y.md\u0000UU conflicto.c\u0000"
        val status = repository(output(porcelain))
        assertEquals("/home/dev/app", status.root)
        assertEquals("app", status.repositoryName)
        assertEquals(GitBranchInfo("main", "origin/main", 2, 1, hasCommits = true, upstreamGone = false), status.branch)
        assertFalse(status.truncated)
        assertEquals(listOf("src/a.swift", "nuevo.txt", "b2.swift", "notas/x y.md", "conflicto.c"), status.changes.map { it.path })
        assertEquals(
            listOf(GitChangeKind.MODIFIED, GitChangeKind.ADDED, GitChangeKind.RENAMED, GitChangeKind.UNTRACKED, GitChangeKind.CONFLICTED),
            status.changes.map { it.kind },
        )
        assertEquals("b.swift", status.changes[2].originalPath)
        assertEquals(listOf("b.swift", "b2.swift"), status.changes[2].affectedPaths)
        assertEquals("notas", status.changes[3].directory)
        assertEquals("x y.md", status.changes[3].fileName)
        assertTrue(status.changes[4].isConflicted)
    }

    @Test
    fun `repositorio limpio y salida recortada`() {
        val clean = repository(output("## main\u0000"))
        assertTrue(clean.isClean)
        assertNull(clean.branch.upstream)
        val cut = repository(output("## main\u0000 M a.txt\u0000 M b.t"))
        assertEquals(listOf("a.txt"), cut.changes.map { it.path })
        assertTrue(cut.truncated)
    }

    @Test
    fun `cabeceras de rama especiales`() {
        val empty = GitStatusParser.parseBranch("No commits yet on main")
        assertEquals("main", empty.name)
        assertFalse(empty.hasCommits)
        val detached = GitStatusParser.parseBranch("HEAD (no branch)")
        assertNull(detached.name)
        assertTrue(detached.hasCommits)
        val gone = GitStatusParser.parseBranch("feat/x...origin/feat/x [gone]")
        assertEquals("feat/x", gone.name)
        assertEquals("origin/feat/x", gone.upstream)
        assertTrue(gone.upstreamGone)
    }
}

class GitDiffParserTest {

    @Test
    fun `tipos y números de línea`() {
        val diff = GitDiffParser.parse(SAMPLE)
        assertEquals(
            listOf("META", "META", "META", "META", "HUNK", "CONTEXT", "REMOVED", "ADDED", "ADDED", "CONTEXT", "NO_NEWLINE"),
            diff.lines.map { it.kind.name },
        )
        assertEquals(2, diff.additions)
        assertEquals(1, diff.deletions)
        assertTrue(diff.hasContent)
        assertEquals(GitDiffLine(6, GitDiffLineKind.REMOVED, "dos", oldNumber = 2), diff.lines[6])
        assertEquals(3, diff.lines[8].newNumber)
        assertEquals(3, diff.lines[9].oldNumber)
        assertEquals(4, diff.lines[9].newNumber)
    }

    @Test
    fun `binarios, recorte e inicio de hunk`() {
        val binary = GitDiffParser.parse("diff --git a/i.png b/i.png\nBinary files a/i.png and b/i.png differ\n")
        assertTrue(binary.isBinary)
        assertFalse(binary.hasContent)
        val cut = GitDiffParser.parse("@@ -1 +1 @@\n+completa\n+a medi", truncated = true)
        assertTrue(cut.truncated)
        assertEquals("completa", cut.lines.last().text)
        assertEquals(0 to 1, GitDiffParser.hunkStarts("@@ -0,0 +1 @@"))
        assertEquals(7 to 9, GitDiffParser.hunkStarts("@@ -7 +9,2 @@ x"))
        assertNull(GitDiffParser.hunkStarts("@@ roto"))
    }

    companion object {
        val SAMPLE = """
            diff --git a/a.txt b/a.txt
            index 1111111..2222222 100644
            --- a/a.txt
            +++ b/a.txt
            @@ -1,3 +1,4 @@ func main
             uno
            -dos
            +DOS
            +dos y medio
             tres
            \ No newline at end of file

        """.trimIndent()
    }
}

class GitCommandsTest {

    private val tricky = GitFileChange("a'; rm -rf ~ #.txt", null, ' ', 'M')

    @Test
    fun `las rutas peligrosas van entrecomilladas`() {
        val quoted = ShellQuoting.singleQuoted(tricky.path)
        val inner = "git --literal-pathspecs -C '/r' restore --source=HEAD --staged --worktree -- $quoted"
        assertEquals("sh -c " + ShellQuoting.singleQuoted(inner), GitCommands.discard("/r", tricky))
    }

    @Test
    fun `commit solo de las rutas elegidas y renombrado preparado`() {
        val changes = listOf(GitFileChange("a", null, ' ', 'M'), GitFileChange("b", null, '?', '?'))
        val command = GitCommands.commitScript("/r", "feat: x", changes)
        assertTrue("add -A -- 'a' 'b' &&" in command)
        assertTrue("commit -m 'feat: x' -- 'a' 'b'" in command)
        val renamed = GitFileChange("b2.swift", "b.swift", 'R', ' ')
        val rename = GitCommands.commitScript("/r", "m", listOf(renamed))
        assertTrue("add -A -- 'b2.swift' &&" in rename)
        assertTrue("commit -m 'm' -- 'b.swift' 'b2.swift'" in rename)
    }

    @Test
    fun `rutas del commit sin duplicados`() {
        val renamed = GitFileChange("new.txt", "old.txt", 'R', ' ')
        val other = GitFileChange("old.txt", null, '?', '?')
        assertEquals(listOf("old.txt", "new.txt"), GitCommands.commitPaths(listOf(renamed, other)))
    }

    @Test
    fun `el error de git conserva las últimas líneas`() {
        val error = GitCommandException.from("", "fatal: Please tell me who you are.\n", 128)
        assertEquals("fatal: Please tell me who you are.", error.message)
        assertTrue("código 1" in GitCommandException.from("", "", 1).message.orEmpty())
    }
}

class GitSummaryParserTest {

    private val paths = listOf("/srv/app", "/srv/con espacio", "/srv/nada")

    @Test
    fun `parsea por índice de ruta e ignora no-repos y ruido`() {
        val output = """
            bienvenido al servidor
            ARGOS_GSUM 0 5 ## main...origin/main [ahead 2, behind 1]
            ARGOS_GSUM 1 0 ## No commits yet on main
            ARGOS_GSUM 2 -
        """.trimIndent()
        val result = GitSummaryParser.parse(output, paths)
        assertEquals(2, result.size)
        val app = assertNotNull(result["/srv/app"])
        assertEquals(5, app.changedCount)
        assertEquals("main", app.branch.name)
        assertEquals(2, app.branch.ahead)
        assertEquals(1, app.branch.behind)
        assertEquals(false, result["/srv/con espacio"]?.branch?.hasCommits)
        assertNull(result["/srv/nada"])
    }

    @Test
    fun `líneas mal formadas no rompen nada`() {
        val output = "ARGOS_GSUM 9 1 ## main\nARGOS_GSUM x 1 ## main\nARGOS_GSUM 0 1 sin-cabecera\n"
        assertTrue(GitSummaryParser.parse(output, paths).isEmpty())
    }

    @Test
    fun `solo es destacable si hay cambios o commits por subir o traer`() {
        val clean = GitRepoSummary(GitBranchInfo.UNKNOWN, 0)
        assertFalse(clean.isNoteworthy)
        assertTrue("sin cambios" in clean.label)
        val dirty = GitRepoSummary(GitBranchInfo.UNKNOWN, 1)
        assertTrue(dirty.isNoteworthy)
        assertTrue("1 archivo cambiado" in dirty.label)
        assertTrue("2 commits por subir" in GitRepoSummary(GitBranchInfo.UNKNOWN.copy(ahead = 2), 0).label)
    }
}
