package com.iaportafolio.argos.ui.importer

import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy

/**
 * Analizador de CameraX: copia el plano Y de cada fotograma (reutilizando el búfer) y lo pasa a
 * [QrFrameDecoder]. Llama a [onDecoded] en el hilo del analizador con cada texto leído; quien
 * lo recibe filtra repetidos. Siempre cierra la imagen para que llegue el siguiente fotograma.
 */
class QrCodeAnalyzer(
    private val onDecoded: (String) -> Unit,
    private val decoder: QrFrameDecoder = QrFrameDecoder(),
) : ImageAnalysis.Analyzer {

    private var buffer = ByteArray(0)

    override fun analyze(image: ImageProxy) {
        image.use { frame ->
            val plane = frame.planes.firstOrNull() ?: return
            val size = plane.rowStride * frame.height
            if (buffer.size != size) buffer = ByteArray(size)
            val source = plane.buffer.duplicate().apply { rewind() }
            source.get(buffer, 0, minOf(source.remaining(), size))
            decoder.decode(LuminanceFrame(buffer, frame.width, frame.height, plane.rowStride))?.let(onDecoded)
        }
    }
}
