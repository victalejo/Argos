//
//  UploadThumbnail.swift
//  ArgosCore
//
//  Miniatura de lo que se sube al terminal (imagen pegada, foto o archivo de imagen) para
//  ver antes de que llegue al servidor que es la correcta. ImageIO (Mac e iOS, sin UI):
//  decodifica reducido, sin cargar la imagen entera a tamaño completo.
//

import CoreGraphics
import Foundation
import ImageIO

/// Imagen ya reducida; inmutable, por eso se puede pasar entre hilos.
final class UploadThumbnail: @unchecked Sendable {
    /// Lado mayor, en píxeles: nítida a ~120 pt en pantallas Retina.
    static let maxPixelSize = 360

    let image: CGImage

    private init(image: CGImage) {
        self.image = image
    }

    var aspectRatio: CGFloat {
        image.height > 0 ? CGFloat(image.width) / CGFloat(image.height) : 1
    }

    /// `nil` si no es una imagen (o no se puede leer).
    static func make(from source: TerminalUploadRequest.Source) -> UploadThumbnail? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let imageSource: CGImageSource?
        switch source {
        case .data(let data):
            imageSource = CGImageSourceCreateWithData(data as CFData, options)
        case .file(let url):
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            imageSource = CGImageSourceCreateWithURL(url as CFURL, options)
        }
        guard let imageSource, CGImageSourceGetCount(imageSource) > 0 else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions) else { return nil }
        return UploadThumbnail(image: image)
    }
}
