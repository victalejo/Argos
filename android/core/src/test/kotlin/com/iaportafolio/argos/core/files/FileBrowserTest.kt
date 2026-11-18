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
        assertEquals(FileIcon.SPREADSHEET, FileIcon.file("Ventas 2026.XLSX"))
        assertEquals(FileIcon.SPREADSHEET, FileIcon.file("cuentas.ods"))
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
        assertEquals(FilePreviewKind.Html, FilePreview.kind("informe.HTML"))
        assertEquals(FilePreviewKind.Html, FilePreview.kind("viejo.htm"))
        assertEquals(FilePreview.MAX_TEXT_BYTES, FilePreview.readLimit(FilePreviewKind.Html))
    }

    @Test
    fun `texto Windows-1252 o Latin-1 se decodifica en vez de tratarse como binario`() {
        val html = "<html><body>Página de acción €</body></html>".toByteArray(charset("windows-1252"))
        assertFalse(FilePreview.looksBinary(html))
        assertEquals(FilePreviewKind.Html, FilePreview.kind("host.html", html))
        assertTrue(FilePreview.text(html).contains("Página de acción €"))
        // 0x81 no existe en Windows-1252: se cae a Latin-1.
        val latin1 = "caf".toByteArray() + bytes(0xE9, 0x81) +
            " y más texto normal para diluir el control".repeat(3).toByteArray(Charsets.ISO_8859_1)
        assertTrue(FilePreview.text(latin1).startsWith("café"))
    }

    @Test
    fun `UTF-16 con BOM es texto aunque tenga NUL y sin BOM binario`() {
        val withBom = "<p>hola ñ</p>".toByteArray(Charsets.UTF_16)
        assertEquals(FilePreviewKind.Html, FilePreview.kind("a.html", withBom))
        assertEquals("<p>hola ñ</p>", FilePreview.text(withBom))
        val littleEndian = bytes(0xFF, 0xFE) + "<p>ñ</p>".toByteArray(Charsets.UTF_16LE)
        assertEquals("<p>ñ</p>", FilePreview.text(littleEndian))
        // Bloque truncado a mitad de una unidad de 16 bits.
        assertTrue(FilePreview.text(withBom.copyOf(withBom.size - 1)).startsWith("<p>hola"))
        assertTrue(FilePreview.looksBinary("<p>hola</p>".toByteArray(Charsets.UTF_16LE)))
    }

    @Test
    fun `UTF-8 valido se decodifica tal cual`() {
        assertEquals("<h1>Título</h1>", FilePreview.text("<h1>Título</h1>".toByteArray()))
        assertEquals(null, FilePreview.decodeText(bytes(0x00, 0x41)))
    }

    // Hojas de cálculo (paridad con `SpreadsheetPreviewTests.swift`, commit f5a1220)

    @ParameterizedTest
    @CsvSource("datos.xlsx", "Informe.XLSX", "macros.xlsm", "viejo.xls", "plan.numbers")
    fun `Excel y Numbers se reconocen por extension y leen hasta su limite`(name: String) {
        assertEquals(FilePreviewKind.Spreadsheet, FilePreview.kind(name))
        assertEquals(FilePreview.MAX_SPREADSHEET_BYTES, FilePreview.readLimit(FilePreviewKind.Spreadsheet))
    }

    @Test
    fun `con bytes ZIP u OLE2 es hoja de calculo y otra cosa binario`() {
        val zip = bytes(0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x06, 0x00)
        val ole = bytes(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1)
        assertEquals(FilePreviewKind.Spreadsheet, FilePreview.kind("a.xlsx", zip))
        assertEquals(FilePreviewKind.Spreadsheet, FilePreview.kind("a.xls", ole))
        assertEquals(FilePreviewKind.Binary, FilePreview.kind("a.xlsx", "no soy excel".toByteArray()))
        assertEquals(FilePreviewKind.Binary, FilePreview.kind("a.xlsx", ByteArray(0)))
        assertEquals(FilePreviewKind.Code(null), FilePreview.kind("datos.csv", "a,b\n1,2\n".toByteArray()))
    }

    @Test
    fun `el nombre del servidor no puede escapar de la carpeta temporal`() {
        val cases = listOf(
            "../../etc/passwd.xlsx" to "passwd.xlsx",
            "/tmp/x/datos.xlsx" to "datos.xlsx",
            ".." to "archivo",
            "" to "archivo",
            "a\u0000b\u0007.xlsx" to "ab.xlsx",
            "..oculto.xlsx" to "oculto.xlsx",
            "c:\\x\\y.xls" to "cxy.xls",
        )
        for ((input, expected) in cases) assertEquals(expected, PreviewTempFileName.safe(input), input)
        assertEquals(200, PreviewTempFileName.safe("a".repeat(300) + ".xlsx").length)
        assertEquals("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", SpreadsheetMime.of("Ventas.XLSX"))
        assertEquals("application/vnd.ms-excel", SpreadsheetMime.of("viejo.xls"))
        assertEquals(SpreadsheetMime.GENERIC, SpreadsheetMime.of("sin-extension"))
    }

    @Test
    fun `binario NUL o UTF-8 invalido y texto con multibyte cortado no lo es`() {
        assertTrue(FilePreview.looksBinary(byteArrayOf(0x48, 0x00, 0x49)))
        // Vector de Swift tras c40ab9b: controles C1 que ni Windows-1252 ni Latin-1 hacen texto.
        assertTrue(FilePreview.looksBinary(bytes(0x80, 0x81, 0x8D, 0x8F, 0x90, 0x9D, 0x01, 0x02)))
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
