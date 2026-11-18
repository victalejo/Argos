//
//  SafeLocalFile.swift
//  Argos
//
//  Ruta LOCAL para un archivo cuyo nombre viene del servidor (listado SFTP, búsqueda):
//  un servidor comprometido podría devolver «../../algo» o un nombre con «/» y hacer
//  que la app escriba fuera de su carpeta temporal. Lógica pura: se limpia el nombre
//  (`QuickLookTempFile.safeName`: último componente, sin separadores ni caracteres de
//  control, sin puntos iniciales, longitud acotada) y se comprueba que la URL final
//  queda EXACTAMENTE dentro de la carpeta de destino.
//

import Foundation

enum SafeLocalFile {
    enum PathError: LocalizedError, Equatable {
        case outsideDestination

        var errorDescription: String? {
            String(localized: "El nombre del archivo que envió el servidor no es válido para guardarlo en este dispositivo.")
        }
    }

    /// Nombre de respaldo cuando el del servidor no sirve; conserva una extensión
    /// segura (letras y números, hasta 10) para que otras apps sepan abrirlo.
    static func fallbackName(for remoteName: String) -> String {
        let ext = (remoteName as NSString).pathExtension
        let safeExt = !ext.isEmpty && ext.count <= 10 && ext.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
        return safeExt ? "archivo.\(ext)" : "archivo"
    }

    /// Nombre local limpio para `remoteName`.
    static func name(for remoteName: String) -> String {
        let cleaned = QuickLookTempFile.safeName(remoteName)
        let invalid = cleaned.isEmpty || cleaned == "." || cleaned == ".."
            || cleaned.contains("/") || cleaned.contains("\\") || cleaned.contains("\u{0}")
        return invalid ? fallbackName(for: remoteName) : cleaned
    }

    /// URL dentro de `folder` para `remoteName`. Lanza si, aun limpia, saliera de ella.
    static func url(for remoteName: String, in folder: URL) throws -> URL {
        let destination = folder.standardizedFileURL
        let url = destination.appendingPathComponent(name(for: remoteName), isDirectory: false).standardizedFileURL
        guard url.deletingLastPathComponent().path == destination.path,
              url.lastPathComponent != "..", url.lastPathComponent != "."
        else { throw PathError.outsideDestination }
        return url
    }
}
