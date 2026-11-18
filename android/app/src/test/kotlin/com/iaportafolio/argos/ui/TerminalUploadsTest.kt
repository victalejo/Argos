package com.iaportafolio.argos.ui

import com.iaportafolio.argos.core.TerminalAttachment
import com.iaportafolio.argos.data.AttachmentSource
import com.iaportafolio.argos.data.PickedAttachment
import com.iaportafolio.argos.testing.FakeSSHService
import com.iaportafolio.argos.ui.terminal.AttachmentKind
import com.iaportafolio.argos.ui.terminal.TerminalNotice
import com.iaportafolio.argos.ui.terminal.TerminalUploads
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import java.time.Instant
import java.time.ZoneId
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/** Subir lo adjuntado al terminal y teclear su ruta (como `TouchTerminalController.attach`). */
class TerminalUploadsTest {

    private class BytesSource(var bytes: ByteArray = "hola".toByteArray()) : AttachmentSource {
        val reads = mutableListOf<Pair<String, Int>>()
        override fun describe(uri: String) = PickedAttachment(uri, null, null, null)
        override suspend fun read(uri: String, maxBytes: Int): ByteArray {
            reads += uri to maxBytes
            return bytes
        }
    }

    private val source = BytesSource()
    private val service = FakeSSHService()
    private val notices = mutableListOf<TerminalNotice>()
    private val typed = mutableListOf<String>()
    private val now = Instant.parse("2026-11-18T09:05:07Z")

    private fun file(name: String?, mime: String? = null, size: Long? = 4) = PickedAttachment("content://x/1", name, mime, size)

    @Test
    fun `sube con su nombre, teclea la ruta con espacio y avisa`() = runTest {
        val uploads = TerminalUploads(source, StandardTestDispatcher(testScheduler)) { now }
        val result = uploads.upload(service, file("informe.pdf"), AttachmentKind.FILE, notices::add) { typed += it; true }

        assertEquals(TerminalNotice.Uploaded("informe.pdf", "/tmp/argos-1-informe.pdf", typedPath = true), result)
        assertEquals(listOf(TerminalNotice.Uploading("informe.pdf"), result), notices)
        assertEquals(listOf("/tmp/argos-1-informe.pdf "), typed)
        assertEquals("informe.pdf", service.uploads.single().first)
        assertEquals(TerminalAttachment.MAX_BYTES, source.reads.single().second)
    }

    @Test
    fun `una imagen pegada usa la subida de pegado con su extension`() = runTest {
        val uploads = TerminalUploads(source, StandardTestDispatcher(testScheduler)) { now }
        val result = uploads.upload(service, file(null, "image/jpeg", null), AttachmentKind.PASTED_IMAGE, notices::add) { false }
        assertEquals("pasted.jpg", service.uploads.single().first)
        assertEquals(TerminalNotice.Uploaded("imagen.jpg", "/tmp/argos-pasted-1.jpg", typedPath = false), result)
    }

    @Test
    fun `una foto sin nombre se llama foto-fecha`() {
        val uploads = TerminalUploads(source, StandardTestDispatcher()) { now }
        val expected = TerminalAttachment.photoFileName("png", now, ZoneId.systemDefault())
        assertEquals(expected, uploads.label(file(null, "image/png"), AttachmentKind.PHOTO))
        assertEquals("archivo", uploads.label(file(null, "application/zip"), AttachmentKind.FILE))
    }

    @Test
    fun `demasiado grande no se lee entero ni se sube`() = runTest {
        val uploads = TerminalUploads(source, StandardTestDispatcher(testScheduler)) { now }
        val declared = uploads.upload(service, file("video.mov", size = TerminalAttachment.MAX_BYTES + 1L), AttachmentKind.FILE, notices::add) { true }
        assertIs<TerminalNotice.Failed>(declared)
        assertTrue(source.reads.isEmpty())

        source.bytes = ByteArray(TerminalAttachment.MAX_BYTES + 1)
        val read = uploads.upload(service, file("sin-tamano.bin", size = null), AttachmentKind.FILE, notices::add) { true }
        assertEquals(TerminalNotice.Failed(TerminalAttachment.tooLargeMessage("sin-tamano.bin")), read)
        assertTrue(service.uploads.isEmpty())
    }

    @Test
    fun `un fallo de la subida queda en el aviso sin lanzar`() = runTest {
        service.uploadError = java.io.IOException("sin espacio")
        val uploads = TerminalUploads(source, StandardTestDispatcher(testScheduler)) { now }
        val result = uploads.upload(service, file("a.txt"), AttachmentKind.FILE, notices::add) { true }
        val failed = assertIs<TerminalNotice.Failed>(result)
        assertTrue(failed.message.startsWith("No se pudo subir «a.txt»"))
        assertTrue(typed.isEmpty())
    }
}
