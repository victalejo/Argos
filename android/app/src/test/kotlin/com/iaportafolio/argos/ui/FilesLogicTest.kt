package com.iaportafolio.argos.ui

import com.iaportafolio.argos.core.files.FileDownloadStatus
import com.iaportafolio.argos.core.files.SyntaxHighlighter
import com.iaportafolio.argos.ui.files.Breadcrumb
import com.iaportafolio.argos.ui.files.CodePalette
import com.iaportafolio.argos.ui.files.CountingOutputStream
import com.iaportafolio.argos.ui.files.DownloadState
import com.iaportafolio.argos.ui.files.FileSearch
import com.iaportafolio.argos.ui.files.FilesUiState
import com.iaportafolio.argos.ui.files.FolderParent
import com.iaportafolio.argos.ui.files.SafeLinkPolicy
import com.iaportafolio.argos.ui.files.highlightedLines
import org.junit.jupiter.api.Test
import java.io.ByteArrayOutputStream
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class FilesLogicTest {

    @Test
    fun `solo se abren enlaces http https y mailto (paridad con Apple)`() {
        assertTrue(SafeLinkPolicy.isAllowed("https://nextjs.org"))
        assertTrue(SafeLinkPolicy.isAllowed("HTTP://example.com"))
        assertTrue(SafeLinkPolicy.isAllowed("mailto:a@b.co"))
        assertFalse(SafeLinkPolicy.isAllowed("file:///etc/passwd"))
        assertFalse(SafeLinkPolicy.isAllowed("x-apple-systempreferences:com.apple"))
        assertFalse(SafeLinkPolicy.isAllowed("javascript:alert(1)"))
        assertFalse(SafeLinkPolicy.isAllowed("intent://scan/#Intent;scheme=zxing;end"))
        assertFalse(SafeLinkPolicy.isAllowed("content://com.android.contacts/1"))
        assertFalse(SafeLinkPolicy.isAllowed("docs/README.md"))
        assertFalse(SafeLinkPolicy.isAllowed("ht tp://mal"))
    }

    @Test
    fun `migas de pan desde la raíz del proyecto`() {
        assertEquals(listOf(Breadcrumb("app", "/srv/app")), FilesUiState.breadcrumbs("/srv/app", "/srv/app"))
        assertEquals(
            listOf(Breadcrumb("app", "/srv/app"), Breadcrumb("src", "/srv/app/src"), Breadcrumb("ui", "/srv/app/src/ui")),
            FilesUiState.breadcrumbs("/srv/app", "/srv/app/src/ui"),
        )
        assertEquals(listOf(Breadcrumb("/", "/")), FilesUiState.breadcrumbs("/", "/"))
        assertEquals(listOf(Breadcrumb("/", "/"), Breadcrumb("etc", "/etc")), FilesUiState.breadcrumbs("/", "/etc"))
    }

    @Test
    fun `la carpeta padre nunca sube por encima de la raíz`() {
        assertEquals("/srv/app", FolderParent.of("/srv/app/src", "/srv/app"))
        assertEquals("/srv/app", FolderParent.of("/srv/app", "/srv/app"))
        assertEquals("/srv/app/src", FolderParent.of("/srv/app/src/ui/", "/srv/app"))
    }

    @Test
    fun `búsqueda difusa sin acentos, nombre antes que carpeta y con tope`() {
        val paths = listOf("pages/x.tsx", "src/page.tsx", "docs/Página.md", "z.txt")
        val results = FileSearch.rank("pagina", paths)
        assertEquals("docs/Página.md", results.first())
        assertEquals("src/page.tsx", FileSearch.rank("page", paths).first())
        assertTrue(FileSearch.rank("", paths).isEmpty())
        assertTrue(FileSearch.rank("qqq", paths).isEmpty())
        val many = (1..500).map { "f$it.txt" }
        assertEquals(FileSearch.MAX_RESULTS, FileSearch.rank("f", many).size)
    }

    @Test
    fun `el contador agrupa avisos de progreso y no cierra el destino`() {
        val target = object : ByteArrayOutputStream() {
            var closed = false
            override fun close() {
                closed = true
            }
        }
        val reports = mutableListOf<Long>()
        val counting = CountingOutputStream(target, reportEveryBytes = 10) { reports += it }
        counting.write(ByteArray(4))
        counting.write(ByteArray(4))
        assertTrue(reports.isEmpty())
        counting.write(ByteArray(4))
        assertEquals(listOf(12L), reports)
        counting.write(7)
        counting.close()
        assertEquals(listOf(12L, 13L), reports)
        assertEquals(13L, counting.count)
        assertEquals(13, target.size())
        assertFalse(target.closed)
    }

    @Test
    fun `fracción de descarga con y sin tamaño`() {
        val downloading = FileDownloadStatus.Downloading("a")
        assertEquals(0.5f, DownloadState("a", downloading, 5, 10).fraction)
        assertNull(DownloadState("a", downloading, 5, null).fraction)
        assertEquals(1f, DownloadState("a", downloading, 50, 10).fraction)
    }

    @Test
    fun `el resaltado se reparte por líneas conservando los colores`() {
        val text = "/* a\nb */ let x\nreturn"
        val tokens = SyntaxHighlighter.tokens(text, "swift")
        val lines = highlightedLines(text, tokens, CodePalette.Light)
        assertEquals(listOf("/* a", "b */ let x", "return"), lines.map { it.text })
        assertEquals(CodePalette.Light.comment, lines[1].spanStyles.first().item.color)
        assertEquals(CodePalette.Light.keyword, lines[2].spanStyles.single().item.color)
        assertEquals(listOf(""), highlightedLines("", emptyList(), CodePalette.Dark).map { it.text })
    }
}
