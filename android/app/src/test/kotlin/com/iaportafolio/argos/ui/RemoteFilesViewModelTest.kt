@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.ui

import app.cash.turbine.test
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.files.FileBrowserException
import com.iaportafolio.argos.core.files.FileDownloadStatus
import com.iaportafolio.argos.core.files.FilePreview
import com.iaportafolio.argos.core.files.SyntaxHighlighter
import com.iaportafolio.argos.testing.FakeDocumentWriter
import com.iaportafolio.argos.testing.FakeFileService
import com.iaportafolio.argos.testing.FakeSSHService
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.MainDispatcherExtension
import com.iaportafolio.argos.testing.SingleServiceProvider
import com.iaportafolio.argos.testing.dir
import com.iaportafolio.argos.testing.file
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.files.Breadcrumb
import com.iaportafolio.argos.ui.files.DirectoryLoad
import com.iaportafolio.argos.ui.files.DownloadRequest
import com.iaportafolio.argos.ui.files.FilesEvent
import com.iaportafolio.argos.ui.files.PreviewContent
import com.iaportafolio.argos.ui.files.RemoteFilesViewModel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.RegisterExtension
import java.io.IOException
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RemoteFilesViewModelTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val root = "/srv/app"
    private val repository = InMemoryServerRepository(listOf(server()))
    private val files = FakeFileService()
    private val writer = FakeDocumentWriter()

    init {
        files.directories[root] = listOf(
            file(root, "file10.txt"),
            dir(root, "src"),
            file(root, "file2.txt"),
            dir(root, "node_modules"),
            file(root, ".env"),
            file(root, "README.md"),
        )
        files.directories["$root/src"] = listOf(dir("$root/src", "lib"), file("$root/src", "main.kt"))
        files.directories["$root/src/lib"] = emptyList()
    }

    private fun TestScope.loaded(service: com.iaportafolio.argos.core.SSHServicing = files) =
        RemoteFilesViewModel("S1", root, repository, SingleServiceProvider(service), writer, main.dispatcher).also { advanceUntilIdle() }

    // MARK: - Navegación

    @Test
    fun `lista la raíz con carpetas primero, orden natural y sin ocultos ni ruidosos`() = runTest(main.dispatcher) {
        val vm = loaded()
        val state = vm.state.value
        assertEquals(DirectoryLoad.Loaded, state.load)
        assertEquals(listOf("src", "file2.txt", "file10.txt", "README.md"), state.visibleEntries.map { it.name })
        assertEquals(2, state.hiddenCount)

        vm.setShowHidden(true)
        assertEquals(
            listOf("node_modules", "src", ".env", "file2.txt", "file10.txt", "README.md"),
            vm.state.value.visibleEntries.map { it.name },
        )
    }

    @Test
    fun `navega por carpetas con migas de pan y atrás sube hasta la raíz`() = runTest(main.dispatcher) {
        val vm = loaded()
        vm.openEntry(vm.state.value.visibleEntries.first { it.name == "src" })
        advanceUntilIdle()
        vm.open("$root/src/lib")
        advanceUntilIdle()
        assertEquals(
            listOf(Breadcrumb("app", root), Breadcrumb("src", "$root/src"), Breadcrumb("lib", "$root/src/lib")),
            vm.state.value.breadcrumbs,
        )

        assertTrue(vm.back())
        advanceUntilIdle()
        assertEquals("$root/src", vm.state.value.path)
        assertTrue(vm.back())
        advanceUntilIdle()
        assertTrue(vm.state.value.isAtRoot)
        assertFalse(vm.back())
    }

    @Test
    fun `no sale de la carpeta del proyecto`() = runTest(main.dispatcher) {
        val vm = loaded()
        vm.open("/srv/app-old")
        vm.open("/etc")
        advanceUntilIdle()
        assertEquals(root, vm.state.value.path)
        vm.openFile("/etc/passwd", "passwd", null)
        assertNull(vm.state.value.preview)
    }

    @Test
    fun `symlink fuera del proyecto muestra el error de core`() = runTest(main.dispatcher) {
        files.listError = FileBrowserException.OutsideProject("$root/fuera")
        val vm = loaded()
        val failed = assertIs<DirectoryLoad.Failed>(vm.state.value.load)
        assertTrue((failed.message as UiText.Plain).value.contains("fuera de la carpeta del proyecto"))

        files.listError = null
        vm.open(root)
        advanceUntilIdle()
        assertEquals(DirectoryLoad.Loaded, vm.state.value.load)
    }

    @Test
    fun `servicio sin explorador avisa con un texto propio`() = runTest(main.dispatcher) {
        val vm = loaded(FakeSSHService())
        assertEquals(DirectoryLoad.Failed(UiText.res(R.string.files_unsupported)), vm.state.value.load)
    }

    @Test
    fun `pull to refresh conserva la lista si falla`() = runTest(main.dispatcher) {
        val vm = loaded()
        files.listError = IOException("se cayó")
        vm.refresh()
        advanceUntilIdle()
        assertEquals(DirectoryLoad.Loaded, vm.state.value.load)
        assertEquals(4, vm.state.value.visibleEntries.size)
        assertEquals(UiText.Plain("se cayó"), vm.state.value.message)
        assertFalse(vm.state.value.isRefreshing)
    }

    // MARK: - Búsqueda

    @Test
    fun `la búsqueda indexa una vez y ordena por coincidencia en el nombre`() = runTest(main.dispatcher) {
        files.index = listOf("pages/index.tsx", "src/page.tsx", "docs/paginacion.md", "README.md")
        val vm = loaded()
        vm.openSearch()
        assertTrue(vm.state.value.search.isIndexing)
        advanceUntilIdle()

        vm.onSearchQuery("page")
        advanceUntilIdle()
        assertEquals("src/page.tsx", vm.state.value.search.results.first())
        assertFalse("README.md" in vm.state.value.search.results)

        vm.closeSearch()
        vm.openSearch()
        advanceUntilIdle()
        assertEquals(1, files.indexCalls)
        assertEquals("", vm.state.value.search.query)

        vm.onSearchQuery("readme")
        advanceUntilIdle()
        vm.openSearchResult(vm.state.value.search.results.single())
        assertEquals("$root/README.md", vm.state.value.preview?.path)
        assertTrue(vm.back()) // cierra la vista previa
        assertTrue(vm.back()) // cierra la búsqueda
        assertFalse(vm.state.value.search.isActive)
    }

    @Test
    fun `un fallo al indexar se puede reintentar`() = runTest(main.dispatcher) {
        files.indexError = IOException("find falló")
        val vm = loaded()
        vm.openSearch()
        advanceUntilIdle()
        assertEquals(UiText.Plain("find falló"), vm.state.value.search.error)

        files.indexError = null
        files.index = listOf("a.txt")
        vm.retryIndex()
        vm.onSearchQuery("a")
        advanceUntilIdle()
        assertNull(vm.state.value.search.error)
        assertEquals(listOf("a.txt"), vm.state.value.search.results)
    }

    // MARK: - Vista previa

    @Test
    fun `código se resalta con el lenguaje de FilePreview`() = runTest(main.dispatcher) {
        files.files["$root/src/main.kt"] = "fun main() = 42 // fin".toByteArray()
        val vm = loaded()
        vm.openFile("$root/src/main.kt", "main.kt", 22)
        assertTrue(vm.state.value.preview?.isLoading == true)
        advanceUntilIdle()

        val code = assertIs<PreviewContent.Code>(vm.state.value.preview?.content)
        assertEquals("kotlin", code.language)
        assertTrue(code.tokens.any { it.kind == SyntaxHighlighter.Token.Kind.KEYWORD })
        assertTrue(code.tokens.any { it.kind == SyntaxHighlighter.Token.Kind.COMMENT })
        assertEquals(FilePreview.MAX_TEXT_BYTES, files.reads.single().second)
    }

    @Test
    fun `markdown, imagen y binario eligen su visor`() = runTest(main.dispatcher) {
        files.files["$root/README.md"] = "# Hola".toByteArray()
        files.files["$root/logo.png"] = byteArrayOf(1, 2, 3)
        files.files["$root/app.bin"] = byteArrayOf(0, 1, 2)
        files.files["$root/doc.pdf"] = "%PDF-1.7".toByteArray()
        val vm = loaded()

        vm.openFile("$root/README.md", "README.md", null)
        advanceUntilIdle()
        assertEquals(PreviewContent.Markdown("# Hola"), vm.state.value.preview?.content)

        vm.openFile("$root/logo.png", "logo.png", null)
        advanceUntilIdle()
        assertContentEquals(byteArrayOf(1, 2, 3), assertIs<PreviewContent.Image>(vm.state.value.preview?.content).bytes)
        assertEquals(FilePreview.MAX_IMAGE_BYTES, files.reads.last().second)

        vm.openFile("$root/app.bin", "app.bin", null)
        advanceUntilIdle()
        assertEquals(PreviewContent.Binary, vm.state.value.preview?.content)

        vm.openFile("$root/doc.pdf", "doc.pdf", null)
        advanceUntilIdle()
        assertEquals(PreviewContent.Pdf, vm.state.value.preview?.content)
    }

    @Test
    fun `archivo más grande que el límite se marca truncado`() = runTest(main.dispatcher) {
        val big = ByteArray((FilePreview.MAX_TEXT_BYTES + 10).toInt()) { 'a'.code.toByte() }
        files.files["$root/big.log"] = big
        val vm = loaded()
        vm.openFile("$root/big.log", "big.log", null)
        advanceUntilIdle()
        val preview = assertNotNull(vm.state.value.preview)
        assertTrue(preview.isTruncated)
        assertEquals(big.size.toLong(), preview.size)
        val code = assertIs<PreviewContent.Code>(preview.content)
        assertEquals(FilePreview.MAX_TEXT_BYTES.toInt(), code.text.length)
        assertTrue(code.tokens.isEmpty()) // por encima del límite de resaltado de la UI
    }

    @Test
    fun `error al leer se muestra en la vista previa`() = runTest(main.dispatcher) {
        files.readError = IOException("permiso denegado")
        val vm = loaded()
        vm.openFile("$root/README.md", "README.md", null)
        advanceUntilIdle()
        assertEquals(UiText.Plain("permiso denegado"), vm.state.value.preview?.error)
        vm.closePreview()
        assertNull(vm.state.value.preview)
    }

    // MARK: - Descarga

    @Test
    fun `descargar pide destino y copia el archivo con progreso`() = runTest(main.dispatcher) {
        val data = ByteArray(10) { it.toByte() }
        files.files["$root/file2.txt"] = data
        val vm = loaded()
        val request = DownloadRequest("$root/file2.txt", "file2.txt", 10)

        vm.events.test {
            vm.requestDownload(request.path, request.name, request.size)
            assertEquals(FilesEvent.ChooseDownloadDestination(request), awaitItem())
        }

        val gate = CompletableDeferred<Unit>()
        files.downloadGate = gate
        vm.onDownloadDestination(request, "content://docs/1")
        runCurrent()
        val running = assertNotNull(vm.state.value.download)
        assertEquals(FileDownloadStatus.Downloading("file2.txt"), running.status)
        assertEquals(4L, running.bytesWritten)
        assertEquals(0.4f, running.fraction)

        files.downloadGate = null
        gate.complete(Unit)
        advanceUntilIdle()
        val done = assertNotNull(vm.state.value.download)
        assertEquals(FileDownloadStatus.Saved("content://docs/1"), done.status)
        assertEquals(10L, done.bytesWritten)
        assertContentEquals(data, writer.written["content://docs/1"])

        vm.dismissDownload()
        assertNull(vm.state.value.download)
    }

    @Test
    fun `cancelar el selector no descarga nada`() = runTest(main.dispatcher) {
        val vm = loaded()
        vm.onDownloadDestination(DownloadRequest("$root/file2.txt", "file2.txt", 10), null)
        advanceUntilIdle()
        assertNull(vm.state.value.download)
        assertTrue(writer.written.isEmpty())
    }

    @Test
    fun `cancelar la descarga borra el archivo a medias y avisa`() = runTest(main.dispatcher) {
        files.files["$root/file2.txt"] = ByteArray(10)
        files.downloadGate = CompletableDeferred()
        val vm = loaded()
        vm.onDownloadDestination(DownloadRequest("$root/file2.txt", "file2.txt", 10), "content://docs/2")
        runCurrent()
        assertNotNull(vm.state.value.download)

        // Otra descarga mientras tanto: se rechaza con aviso.
        vm.requestDownload("$root/file10.txt", "file10.txt", 10)
        assertEquals(UiText.res(R.string.files_download_busy), vm.state.value.message)

        vm.cancelDownload()
        advanceUntilIdle()
        assertNull(vm.state.value.download)
        assertEquals(listOf("content://docs/2"), writer.deleted)
        assertEquals(UiText.res(R.string.files_download_cancelled), vm.state.value.message)
    }

    @Test
    fun `una descarga fallida borra el parcial y muestra el error`() = runTest(main.dispatcher) {
        files.files["$root/file2.txt"] = ByteArray(10)
        files.downloadError = IOException("conexión perdida")
        val vm = loaded()
        vm.onDownloadDestination(DownloadRequest("$root/file2.txt", "file2.txt", 10), "content://docs/3")
        advanceUntilIdle()
        assertEquals(FileDownloadStatus.Failed("file2.txt", "conexión perdida"), vm.state.value.download?.status)
        assertEquals(listOf("content://docs/3"), writer.deleted)
    }

    @Test
    fun `copiar ruta avisa`() = runTest(main.dispatcher) {
        val vm = loaded()
        vm.onPathCopied()
        assertEquals(UiText.res(R.string.files_path_copied), vm.state.value.message)
        vm.messageShown()
        assertNull(vm.state.value.message)
    }
}
