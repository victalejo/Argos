package com.iaportafolio.argos.ui

import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.common.BitMatrix
import com.google.zxing.qrcode.QRCodeWriter
import com.iaportafolio.argos.core.keys.ServerTransfer
import com.iaportafolio.argos.testing.IMPORT_NOW
import com.iaportafolio.argos.testing.transfer
import com.iaportafolio.argos.ui.importer.LuminanceFrame
import com.iaportafolio.argos.ui.importer.QrFrameDecoder
import org.junit.jupiter.api.Test
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import kotlin.random.Random
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

/** El decodificador ZXing con QR generados en el test a partir de un `argos://` real. */
class QrFrameDecoderTest {

    private val link = transfer().urlString()
    private val decoder = QrFrameDecoder()

    @Test
    fun `lee el enlace argos de un QR y decodifica el servidor`() {
        val text = decoder.decode(frameOf(qr(link)))
        assertEquals(link, text)
        assertEquals("dev.example.com", ServerTransfer.decode(checkNotNull(text), IMPORT_NOW).host)
    }

    @ParameterizedTest
    @ValueSource(ints = [90, 180, 270])
    fun `lee el QR con el sensor girado`(degrees: Int) {
        assertEquals(link, decoder.decode(frameOf(rotate(qr(link), degrees))))
    }

    @Test
    fun `respeta el relleno de cada fila (rowStride mayor que el ancho)`() {
        assertEquals(link, decoder.decode(frameOf(qr(link), padding = 64)))
    }

    @Test
    fun `lee un QR pequeño dentro de un fotograma grande`() {
        val small = qr(link, size = 320)
        assertEquals(link, decoder.decode(frameOf(small, canvas = 960, offset = 300)))
    }

    @Test
    fun `una imagen lisa no tiene QR`() {
        val blank = ByteArray(400 * 300) { 0x80.toByte() }
        assertNull(decoder.decode(LuminanceFrame(blank, 400, 300)))
    }

    @Test
    fun `una imagen de ruido no tiene QR`() {
        val random = Random(7)
        val noise = ByteArray(640 * 480) { random.nextInt(256).toByte() }
        assertNull(decoder.decode(LuminanceFrame(noise, 640, 480)))
    }

    @Test
    fun `se puede reutilizar tras un fotograma sin QR`() {
        assertNull(decoder.decode(LuminanceFrame(ByteArray(200 * 200), 200, 200)))
        assertEquals(link, decoder.decode(frameOf(qr(link))))
    }

    @Test
    fun `rechaza un búfer que no cubre el fotograma`() {
        assertFailsWith<IllegalArgumentException> { LuminanceFrame(ByteArray(10), 100, 100) }
        assertFailsWith<IllegalArgumentException> { LuminanceFrame(ByteArray(100 * 100), 100, 100, rowStride = 50) }
    }

    // Fotogramas sintéticos: 0 = negro, 255 = blanco, como el plano Y de la cámara.

    private fun qr(text: String, size: Int = 600): BitMatrix =
        QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size, mapOf(EncodeHintType.MARGIN to 4))

    private fun frameOf(matrix: BitMatrix, padding: Int = 0, canvas: Int = matrix.width, offset: Int = 0): LuminanceFrame {
        val stride = canvas + padding
        val data = ByteArray(stride * canvas) { 0xFF.toByte() }
        for (y in 0 until matrix.height) {
            for (x in 0 until matrix.width) {
                if (matrix[x, y]) data[(y + offset) * stride + x + offset] = 0
            }
        }
        return LuminanceFrame(data, canvas, canvas, stride)
    }

    private fun rotate(matrix: BitMatrix, degrees: Int): BitMatrix {
        val size = matrix.width
        val rotated = BitMatrix(size, size)
        for (y in 0 until size) {
            for (x in 0 until size) {
                if (!matrix[x, y]) continue
                when (degrees) {
                    90 -> rotated.set(size - 1 - y, x)
                    180 -> rotated.set(size - 1 - x, size - 1 - y)
                    else -> rotated.set(y, size - 1 - x)
                }
            }
        }
        return rotated
    }
}
