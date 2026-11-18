package com.iaportafolio.argos.core

import java.time.Instant
import java.time.ZoneOffset
import kotlin.test.Test
import kotlin.test.assertEquals

/** Paridad con `TerminalAttachmentTests` de Swift. */
class TerminalAttachmentTest {

    private val date = Instant.parse("2026-11-18T09:05:07Z")

    @Test
    fun `nombre de foto con fecha y extension limpia`() {
        assertEquals("foto-20261118-090507.heic", TerminalAttachment.photoFileName("HEIC", date, ZoneOffset.UTC))
        assertEquals("foto-20261118-090507.jpg", TerminalAttachment.photoFileName(null, date, ZoneOffset.UTC))
        assertEquals("foto-20261118-090507.jpg", TerminalAttachment.photoFileName(".", date, ZoneOffset.UTC))
        assertEquals("foto-20261118-040507.png", TerminalAttachment.photoFileName("p/n g", date, ZoneOffset.ofHours(-5)))
    }

    @Test
    fun `tope y mensajes`() {
        assertEquals(100 * 1024 * 1024, TerminalAttachment.MAX_BYTES)
        assertEquals("«a.mov» pesa más de 100 MB: súbelo de otra forma.", TerminalAttachment.tooLargeMessage("a.mov"))
        assertEquals("/tmp/x.png ", TerminalAttachment.typedPath("/tmp/x.png"))
    }

    @Test
    fun `extension de una imagen pegada`() {
        assertEquals("png", TerminalAttachment.imageExtension("image/png"))
        assertEquals("jpg", TerminalAttachment.imageExtension("image/jpeg"))
        assertEquals("webp", TerminalAttachment.imageExtension("image/webp; q=1"))
        assertEquals("svg", TerminalAttachment.imageExtension("image/svg+xml"))
        assertEquals("png", TerminalAttachment.imageExtension(null))
    }
}
