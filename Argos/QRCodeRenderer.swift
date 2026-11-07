//
//  QRCodeRenderer.swift
//  Argos
//
//  Genera la imagen de un código QR con Core Image (sin dependencias externas).
//

import AppKit
import CoreImage.CIFilterBuiltins

enum QRCodeRenderer {
    /// QR de `text` (negro sobre blanco), escalado sin suavizado para que sea nítido.
    static func image(for text: String, scale: CGFloat = 10) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else {
            Log.ssh.error("No se pudo generar el código QR")
            return nil
        }
        return NSImage(cgImage: cgImage, size: output.extent.size)
    }
}
