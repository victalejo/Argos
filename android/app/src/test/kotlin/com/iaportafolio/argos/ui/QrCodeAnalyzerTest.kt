package com.iaportafolio.argos.ui

import android.graphics.Rect
import android.media.Image
import androidx.camera.core.ImageInfo
import androidx.camera.core.ImageProxy
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.iaportafolio.argos.testing.transfer
import com.iaportafolio.argos.ui.importer.QrCodeAnalyzer
import org.junit.jupiter.api.Test
import java.nio.ByteBuffer
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** El analizador de CameraX con un `ImageProxy` sintético (plano Y con relleno por fila). */
class QrCodeAnalyzerTest {

    private val link = transfer().urlString()

    @Test
    fun `lee el QR del plano Y y cierra siempre la imagen`() {
        val results = mutableListOf<String>()
        val analyzer = QrCodeAnalyzer({ results += it })
        val frame = FakeImage(qrPlane(link, padding = 32))

        analyzer.analyze(frame)
        assertEquals(listOf(link), results)
        assertTrue(frame.closed)
    }

    @Test
    fun `un fotograma sin QR no avisa pero también se cierra`() {
        val results = mutableListOf<String>()
        val analyzer = QrCodeAnalyzer({ results += it })
        val frame = FakeImage(Plane(ByteBuffer.wrap(ByteArray(320 * 240) { 0x7F }), 320, 240, 320))

        analyzer.analyze(frame)
        assertTrue(results.isEmpty())
        assertTrue(frame.closed)
    }

    @Test
    fun `reutiliza el búfer entre fotogramas de distinto tamaño`() {
        val results = mutableListOf<String>()
        val analyzer = QrCodeAnalyzer({ results += it })
        analyzer.analyze(FakeImage(Plane(ByteBuffer.wrap(ByteArray(100 * 100)), 100, 100, 100)))
        analyzer.analyze(FakeImage(qrPlane(link, padding = 0)))
        analyzer.analyze(FakeImage(qrPlane(link, padding = 16)))
        assertEquals(listOf(link, link), results)
    }

    /** El último renglón de la cámara puede no llevar relleno: el búfer es más corto. */
    @Test
    fun `admite un búfer sin el relleno de la última fila`() {
        val results = mutableListOf<String>()
        val full = qrPlane(link, padding = 24)
        val trimmed = ByteBuffer.wrap(full.bytes.array(), 0, full.bytes.capacity() - 24).slice()
        QrCodeAnalyzer({ results += it }).analyze(FakeImage(full.copy(bytes = trimmed)))
        assertEquals(listOf(link), results)
    }

    private fun qrPlane(text: String, padding: Int): Plane {
        val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 600, 600, mapOf(EncodeHintType.MARGIN to 4))
        val stride = matrix.width + padding
        val data = ByteArray(stride * matrix.height) { 0xFF.toByte() }
        for (y in 0 until matrix.height) {
            for (x in 0 until matrix.width) if (matrix[x, y]) data[y * stride + x] = 0
        }
        return Plane(ByteBuffer.wrap(data), matrix.width, matrix.height, stride)
    }

    private data class Plane(val bytes: ByteBuffer, val width: Int, val height: Int, val stride: Int)

    private class FakeImage(private val plane: Plane) : ImageProxy {
        var closed = false

        override fun close() {
            closed = true
        }

        override fun getCropRect(): Rect = Rect()
        override fun setCropRect(rect: Rect?) = Unit
        override fun getFormat(): Int = YUV_420_888
        override fun getHeight(): Int = plane.height
        override fun getWidth(): Int = plane.width
        override fun getPlanes(): Array<ImageProxy.PlaneProxy> = arrayOf(
            object : ImageProxy.PlaneProxy {
                override fun getRowStride(): Int = plane.stride
                override fun getPixelStride(): Int = 1
                override fun getBuffer(): ByteBuffer = plane.bytes
            },
        )
        override fun getImageInfo(): ImageInfo = throw UnsupportedOperationException()
        override fun getImage(): Image? = null

        private companion object {
            const val YUV_420_888 = 0x23
        }
    }
}
