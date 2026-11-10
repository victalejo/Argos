package com.iaportafolio.argos.core.git

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** «Ramas en paralelo» (paridad con `ArgosTests/WorktreeTests.swift`). */
class GitWorktreeTest {

    private fun golden(name: String): String =
        requireNotNull(javaClass.getResource("/swift-golden/$name.txt")) { "falta $name" }.readText(Charsets.UTF_8)

    private val output = """
        motd
        ARGOS_WT:list
        worktree /srv/app
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /srv/app-worktrees/feat-login
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/feat/login
        locked en uso

        worktree /srv/app-worktrees/viejo
        HEAD 3333333333333333333333333333333333333333
        detached
        prunable gitdir file points to non-existent location

        ARGOS_WT:end
        ARGOS_WT:dirty 0 /srv/app
        ARGOS_WT:dirty 4 /srv/app-worktrees/feat-login
        ARGOS_WT:branch feat/login
        ARGOS_WT:branch fix/x
        ARGOS_WT:branch main
    """.trimIndent()

    private val listing get() = assertIs<GitWorktreeListResult.Loaded>(GitWorktreeParser.parseList(output)).listing

    @Test
    fun `comandos idénticos a Swift`() {
        assertEquals(golden("wt-list"), GitWorktreeCommands.list("/home/u/mi repo's"))
        assertEquals(
            golden("wt-add-new"),
            GitWorktreeCommands.add(GitWorktreeRequest("/home/u/mi repo's", "feat/login", true, "main", "/home/u/mi repo's-worktrees/feat-login")),
        )
        assertEquals(
            golden("wt-add-existing"),
            GitWorktreeCommands.add(GitWorktreeRequest("/srv/app", "fix/x", false, "", "/srv/app-worktrees/fix-x")),
        )
        assertEquals(golden("wt-remove"), GitWorktreeCommands.remove("/srv/app", "/srv/app-worktrees/a b", force = false))
        assertEquals(golden("wt-remove-force"), GitWorktreeCommands.remove("/srv/app", "/srv/app-worktrees/a b", force = true))
    }

    @Test
    fun `principal, ramas, desacoplado, bloqueado, perdido, cambios y ramas libres`() {
        val listing = listing
        assertEquals(listOf("/srv/app", "/srv/app-worktrees/feat-login", "/srv/app-worktrees/viejo"), listing.worktrees.map { it.path })
        assertEquals(listOf(true, false, false), listing.worktrees.map { it.isMain })
        assertEquals("feat/login", listing.worktrees[1].branch)
        assertTrue(listing.worktrees[1].isLocked)
        assertEquals(4, listing.worktrees[1].changedCount)
        assertEquals("HEAD desacoplado (3333333)", listing.worktrees[2].displayBranch)
        assertTrue(listing.worktrees[2].isPrunable)
        assertNull(listing.worktrees[2].changedCount)
        assertEquals(listOf("fix/x"), listing.freeBranches)
        assertEquals("/srv/app-worktrees/feat-otra", listing.defaultPath("feat/otra"))
    }

    @Test
    fun `repo bare, sin git, fuera de un repo y salida del alta`() {
        val bare = GitWorktreeParser.parsePorcelain(listOf("worktree /srv/app.git", "bare", "", "worktree /srv/w", "HEAD abc", "branch refs/heads/x"))
        assertEquals(listOf("/srv/w"), bare.map { it.path })
        assertFalse(bare.single().isMain)
        assertEquals(GitWorktreeListResult.GitMissing, GitWorktreeParser.parseList("ARGOS_WT:nogit\n"))
        assertEquals(GitWorktreeListResult.NotRepository, GitWorktreeParser.parseList("ARGOS_WT:norepo\n"))
        assertEquals("/srv/w x", GitWorktreeParser.addedPath("Preparing\nARGOS_WT:path /srv/w x\n"))
        assertEquals(GitWorktreeRequest.INVALID_BRANCH, GitWorktreeParser.addRefusal("ARGOS_WT:badbranch"))
        assertNull(GitWorktreeParser.addRefusal("ARGOS_WT:path /x"))
    }

    @Test
    fun `nombres de rama y slugs`() {
        listOf("feat/login", "fix-1.2", "v1").forEach { assertTrue(GitBranchName.isValid(it), it) }
        listOf("-x", "a b", "a..b", "a~1", "a^", "a:b", "x.lock", "x/", "/x", "a//b", "@", "a@{1}", ".oculta", "a/.b", "a*", "")
            .forEach { assertFalse(GitBranchName.isValid(it), it) }
        assertEquals("feat-login", GitBranchName.slug("feat/login"))
        assertEquals("release-v1-2", GitBranchName.projectSlug("release/v1.2"))
    }

    @Test
    fun `validación de la petición`() {
        val listing = listing
        val exists = assertFailsWith<GitWorktreeRequest.InvalidException> { GitWorktreeRequest.make(listing, "main", true, "HEAD", "/srv/w") }
        assertEquals(GitWorktreeRequest.BRANCH_EXISTS, exists.message)
        val inUse = assertFailsWith<GitWorktreeRequest.InvalidException> { GitWorktreeRequest.make(listing, "feat/login", false, "", "/srv/w") }
        assertEquals(GitWorktreeRequest.BRANCH_IN_USE, inUse.message)
        assertFailsWith<GitWorktreeRequest.InvalidException> { GitWorktreeRequest.make(listing, "nueva", true, "HEAD", "srv/w") }
        assertFailsWith<GitWorktreeRequest.InvalidException> { GitWorktreeRequest.make(listing, "nueva", true, "HEAD", "/srv/../etc") }
        val request = GitWorktreeRequest.make(listing, " fix/x ", false, "", "/srv/w")
        assertEquals("fix/x", request.branch)
        assertEquals("/srv/app", request.repository)
    }
}
