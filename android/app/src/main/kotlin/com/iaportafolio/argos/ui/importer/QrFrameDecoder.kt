package com.iaportafolio.argos.ui.importer

import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.ChecksumException
import com.google.zxing.DecodeHintType
import com.google.zxing.FormatException
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader

/**
 * Un fotograma en escala de grises: el plano Y (luminancia) de una imagen YUV_420_888, con
 * [rowStride] ≥ [width] (las cámaras rellenan cada fila). En el plano Y el `pixelStride` es
 * siempre 1. [data] debe tener al menos `rowStride * (height - 1) + width` bytes.
 */
class LuminanceFrame(val data: ByteArray, val width: Int, val height: Int, val rowStride: Int = width) {
    init {
        require(width > 0 && height > 0 && rowStride >= width) { "Dimensiones de fotograma no válidas" }
        require(data.size >= rowStride * (height - 1) + width) { "El búfer no cubre el fotograma" }
    }
}

/**
 * Busca un código QR en un fotograma con ZXing (solo QR, `TRY_HARDER`), sin red ni servicios
 * de Google. Lógica pura: se prueba en la JVM.
 *
 * La rotación del sensor no se corrige: la detección de QR de ZXing es invariante a la rotación
 * (busca los tres patrones de posición), así que se ahorra copiar el búfer en cada fotograma.
 * Los tests lo fijan para 90°, 180° y 270°.
 *
 * No es seguro entre hilos: un decodificador por analizador (CameraX llama siempre desde el
 * mismo ejecutor).
 */
class QrFrameDecoder {
    private val reader = QRCodeReader()
    private val hints: Map<DecodeHintType, Any> = mapOf(
        DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
        DecodeHintType.TRY_HARDER to true,
        DecodeHintType.CHARACTER_SET to Charsets.UTF_8.name(),
    )

    /** Texto del QR, o `null` si no hay ninguno legible en el fotograma. */
    fun decode(frame: LuminanceFrame): String? {
        val source = PlanarYUVLuminanceSource(
            frame.data, frame.rowStride, frame.height, 0, 0, frame.width, frame.height, false,
        )
        return try {
            reader.decode(BinaryBitmap(HybridBinarizer(source)), hints).text
        } catch (_: NotFoundException) {
            null
        } catch (_: ChecksumException) {
            null
        } catch (_: FormatException) {
            null
        } finally {
            reader.reset()
        }
    }
}
