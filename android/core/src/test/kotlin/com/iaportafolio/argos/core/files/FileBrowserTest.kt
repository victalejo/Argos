package com.iaportafolio.argos.core.files

import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.CsvSource
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Paridad con `ArgosTests/FileBrowserTests.swift` (sin el resaltado ni los enlaces, que son de UI). */
class FileBrowserTest {

    private fun entry(name: String, kind: RemoteFileEntry.Kind) = RemoteFileEntry(name, "/p/$name", kind)

    // Entradas

    @Test
    fun `tipo desde st_mode carpeta symlink y archivo`() {
        assertEquals(
            RemoteFileEntry.Kind.DIRECTORY,
            RemoteFileEntry.fromAttributes("src", "/p", "40755".toInt(8), null, null).kind,
        )
        assertEquals(
            RemoteFileEntry.Kind.SYMLINK,
            RemoteFileEntry.fromAttributes("l", "/p", "120777".toInt(8), null, null).kind,
        )
        val file = RemoteFileEntry.fromAttributes("a.ts", "/p/", "100644".toInt(8), 3, null)
        assertEquals("/p/a.ts", file.path)
        assertEquals(RemoteFileEntry.Kind.FILE, file.kind)
        assertEquals(RemoteFileEntry.Kind.FILE, RemoteFileEntry.fromAttributes("x", "/p", null, null, null).kind)
    }

    @Test
    fun `orden carpetas primero y orden natural`() {
        val entries = listOf(
            entry("file10.txt", RemoteFileEntry.Kind.FILE),
            entry("zeta", RemoteFileEntry.Kind.DIRECTORY),
            entry("file2.txt", RemoteFileEntry.Kind.FILE),
            entry("Alpha", RemoteFileEntry.Kind.DIRECTORY),
        )
        assertEquals(
            listOf("Alpha", "zeta", "file2.txt", "file10.txt"),
            RemoteFileEntry.sorted(entries).map { it.name },
        )
    }

    @Test
    fun `ocultos y carpetas pesadas solo con mostrar ocultos`() {
        val git = entry(".git", RemoteFileEntry.Kind.DIRECTORY)
        assertTrue(!git.isVisible(showHidden = false) && git.isVisible(showHidden = true))
        assertFalse(entry("node_modules", RemoteFileEntry.Kind.DIRECTORY).isVisible(showHidden = false))
        assertFalse(entry(".env", RemoteFileEntry.Kind.FILE).isVisible(showHidden = false))
        assertTrue(entry("src", RemoteFileEntry.Kind.DIRECTORY).isVisible(showHidden = false))
        assertTrue(entry("build", RemoteFileEntry.Kind.FILE).isVisible(showHidden = false), "un ARCHIVO llamado build no se oculta")
    }

    @Test
    fun `contencion por componentes app-old no esta dentro de app`() {
        assertTrue(RemotePath.isInside("/srv/app/src/a.ts", root = "/srv/app"))
        assertTrue(RemotePath.isInside("/srv/app", root = "/srv/app/"))
        assertFalse(RemotePath.isInside("/srv/app-old/a.ts", root = "/srv/app"))
        assertFalse(RemotePath.isInside("/etc/passwd", root = "/srv/app"))
        assertTrue(RemotePath.isInside("/etc/passwd", root = "/"))
        assertEquals("src/a.ts", RemotePath.relative("/srv/app/src/a.ts", root = "/srv/app"))
    }

    @ParameterizedTest
    @CsvSource(
        "a.tar.gz, gz", "x.TS, ts", ".env, ''", ".gitignore, ''", "Dockerfile, ''",
        "a.txt/, txt", "'foo.bar baz', ''", "a., ''", ".env.local, local", "dir.d/file, ''",
    )
    fun `extension como NSString pathExtension`(name: String, expected: String) {
        assertEquals(expected, RemotePath.fileExtension(name))
    }

    // Iconos

    @Test
    fun `carpetas comunes con icono propio y el resto generico`() {
        assertEquals(FileIcon.SOURCE_FOLDER, FileIcon.folder("src"))
        assertEquals(FileIcon.DOCS_FOLDER, FileIcon.folder("docs"))
        assertEquals(FileIcon.TESTS_FOLDER, FileIcon.folder("tests"))
        assertEquals(FileIcon.CI_FOLDER, FileIcon.folder(".github"))
        assertEquals(FileIcon.DEPENDENCIES_FOLDER, FileIcon.folder("node_modules"))
        assertEquals(FileIcon.DEPENDENCIES_FOLDER, FileIcon.folder("Pods"))
        assertEquals(FileIcon.COMPONENTS_FOLDER, FileIcon.folder("Components"))
        assertEquals(FileIcon.GENERIC_FOLDER, FileIcon.folder("mi-carpeta"))
    }

    @Test
    fun `archivos por nombre exacto y extension`() {
        assertEquals(FileIcon.PACKAGE_MANIFEST, FileIcon.file("package.json"))
        assertEquals(FileIcon.README, FileIcon.file("README.md"))
        assertEquals(FileIcon.MARKDOWN, FileIcon.file("notas.md"))
        assertEquals(FileIcon.ENV, FileIcon.file(".env.local"))
        assertEquals(FileIcon.DOCKER, FileIcon.file("Dockerfile.prod"))
        assertEquals(FileIcon.SWIFT, FileIcon.file("App.swift"))
        assertEquals(FileIcon.GENERIC_FILE, FileIcon.file("sin-extension"))
        assertEquals(FileIcon.SYMLINK, FileIcon.of(entry("enlace", RemoteFileEntry.Kind.SYMLINK)))
        assertEquals(FileIconTint.RED, FileIcon.file("package.json").tint)
    }

    // Visor

    @Test
    fun `visor por nombre Markdown imagen y codigo con lenguaje`() {
        assertEquals(FilePreviewKind.Markdown, FilePreview.kind("README.md"))
        assertEquals(FilePreviewKind.Image, FilePreview.kind("logo.PNG"))
        assertEquals(FilePreviewKind.Code("typescript"), FilePreview.kind("page.tsx"))
        assertEquals(FilePreviewKind.Code("shell"), FilePreview.kind("Dockerfile"))
        assertEquals(FilePreviewKind.Code(null), FilePreview.kind("datos.xyz"))
    }

    @Test
    fun `binario NUL o UTF-8 invalido y texto con multibyte cortado no lo es`() {
        assertTrue(FilePreview.looksBinary(byteArrayOf(0x48, 0x00, 0x49)))
        assertTrue(FilePreview.looksBinary(bytes(0xFF, 0xFE, 0xFD, 0xFC, 0x80, 0x81)))
        assertFalse(FilePreview.looksBinary("hola mundo ñ".toByteArray()))
        // "acci" + primer byte de "ó": multibyte cortado al final del bloque leído.
        assertFalse(FilePreview.looksBinary("acci".toByteArray() + bytes(0xC3)))
        assertFalse(FilePreview.looksBinary(ByteArray(0)))
        assertEquals(FilePreviewKind.Binary, FilePreview.kind("a.txt", byteArrayOf(0, 1, 2)))
        assertEquals(FilePreviewKind.Image, FilePreview.kind("foto.png", byteArrayOf(0, 1, 2)))
    }

    @Test
    fun `los pdf se previsualizan como PDF y leen hasta su propio limite`() {
        assertEquals(FilePreviewKind.Pdf, FilePreview.kind("Cotizacion.PDF"))
        assertEquals(FilePreview.MAX_PDF_BYTES, FilePreview.readLimit(FilePreviewKind.Pdf))
        assertEquals(FilePreview.MAX_IMAGE_BYTES, FilePreview.readLimit(FilePreviewKind.Image))
        assertEquals(FilePreview.MAX_TEXT_BYTES, FilePreview.readLimit(FilePreviewKind.Markdown))
    }

    @Test
    fun `con bytes firma PDF es PDF y sin ella binario`() {
        assertEquals(FilePreviewKind.Pdf, FilePreview.kind("a.pdf", "%PDF-1.7\n\u0000\u0001".toByteArray()))
        assertEquals(FilePreviewKind.Pdf, FilePreview.kind("a.pdf", "basura\n%PDF-1.4".toByteArray()))
        assertEquals(FilePreviewKind.Binary, FilePreview.kind("a.pdf", byteArrayOf(0, 1, 2, 3)))
    }

    // Índice de búsqueda rápida

    @Test
    fun `comando del indice entrecomilla la raiz y poda las carpetas pesadas`() {
        val command = FileBrowserCommands.fileIndexCommand("/srv/mi app")
        assertTrue(command.startsWith("cd '/srv/mi app' && find . \\( -name '.cache' -o "))
        assertTrue(command.contains("-o -name 'node_modules' -o"))
        assertTrue(command.endsWith("\\) -prune -o -type f -print 2>/dev/null | head -n 20000"))
        assertEquals(
            RemoteFileEntry.NOISY_DIRECTORIES.size,
            Regex("-name '").findAll(command).count(),
        )
    }

    @Test
    fun `parseo del indice quita el prefijo y las lineas vacias`() {
        assertEquals(
            listOf("src/a.ts", "README.md", "x/./y"),
            FileBrowserCommands.parseFileIndex("./src/a.ts\n./README.md\n\nx/./y\n"),
        )
        assertTrue(FileBrowserCommands.isDotEntry("..") && !FileBrowserCommands.isDotEntry(".env"))
    }

    @Test
    fun `estados de descarga y error fuera del proyecto`() {
        assertEquals(FileDownloadStatus.Saved("/tmp/a.pdf"), FileDownloadStatus.Saved("/tmp/a.pdf"))
        assertEquals(
            "'/etc' está fuera de la carpeta del proyecto (¿un enlace simbólico?).",
            FileBrowserException.OutsideProject("/etc").message,
        )
        assertEquals(
            RemoteFileContent(byteArrayOf(1, 2), 2, null, false),
            RemoteFileContent(byteArrayOf(1, 2), 2, null, false),
        )
    }

    private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }
}
