//
//  QuickLookTempFile.swift
//  Argos
//
//  Vista Rápida (QuickLook) solo previsualiza archivos en disco: el contenido leído del
//  servidor se escribe en una carpeta temporal propia (nombre aleatorio, solo para el
//  usuario) y se borra al cerrar el visor. El nombre que viene del servidor se limpia
//  para que nunca salga de esa carpeta.
//

import Foundation

struct QuickLookTempFile: Sendable {
    let url: URL
    private let directory: URL

    /// Escribe `data` como `<carpeta aleatoria>/<nombre limpio>` dentro de `base`.
    init(data: Data, name: String, base: URL = FileManager.default.temporaryDirectory) throws {
        let directory = base.appendingPathComponent("argos-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent(Self.safeName(name), isDirectory: false)
        try data.write(to: url, options: .atomic)
        self.url = url
        self.directory = directory
    }

    /// Borra el archivo y su carpeta (best-effort: es un temporal).
    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Último componente, sin separadores ni caracteres de control, con su extensión
    /// (Vista Rápida decide el tipo por ella). Nunca vacío ni «.»/«..».
    static func safeName(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        let cleaned = String(last.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && scalar != "/" && scalar != "\\" && scalar != ":"
        }).trimmingCharacters(in: .whitespaces)
        let trimmed = String(cleaned.drop(while: { $0 == "." }))
        guard !trimmed.isEmpty else { return "archivo" }
        return String(trimmed.suffix(200))
    }
}
