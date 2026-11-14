//
//  FilePreview.swift
//  Argos
//
//  Qué visor usar para un archivo (Markdown renderizado, HTML, código, imagen, PDF,
//  binario) y límites de tamaño. Lógica pura: decide a partir del nombre y de los bytes
//  leídos, y decodifica el texto (UTF-8, UTF-16 con BOM o Windows-1252/Latin-1).
//

import Foundation

enum FilePreviewKind: Equatable, Sendable {
    case markdown
    /// Página HTML: se renderiza (con su fuente disponible).
    case html
    case code(language: String?)
    case image
    case pdf
    case binary
}

enum FilePreview {
    /// Por encima de esto solo se lee el principio del archivo (visor en modo "truncado").
    static let maxTextBytes: UInt64 = 2 * 1024 * 1024
    /// Las imágenes se muestran enteras hasta este tamaño.
    static let maxImageBytes: UInt64 = 20 * 1024 * 1024
    /// Los PDF se muestran enteros hasta este tamaño (más grandes: solo descargar).
    static let maxPDFBytes: UInt64 = 50 * 1024 * 1024

    /// Cuánto leer para previsualizar un archivo según su tipo por nombre.
    static func readLimit(for kind: FilePreviewKind) -> UInt64 {
        switch kind {
        case .image: return maxImageBytes
        case .pdf: return maxPDFBytes
        default: return maxTextBytes
        }
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "ico", "tiff", "avif"]
    private static let markdownExtensions: Set<String> = ["md", "mdx", "markdown"]
    private static let htmlExtensions: Set<String> = ["html", "htm", "xhtml"]

    private static let languages: [String: String] = [
        "swift": "swift", "ts": "typescript", "tsx": "typescript", "js": "javascript",
        "jsx": "javascript", "mjs": "javascript", "cjs": "javascript", "py": "python",
        "go": "go", "rs": "rust", "rb": "ruby", "php": "php", "java": "java", "kt": "kotlin",
        "c": "c", "h": "c", "cpp": "cpp", "cs": "csharp", "dart": "dart", "json": "json",
        "yml": "yaml", "yaml": "yaml", "toml": "toml", "sh": "shell", "bash": "shell",
        "zsh": "shell", "sql": "sql", "html": "html", "css": "css", "scss": "css",
        "vue": "html", "svelte": "html", "xml": "html", "dockerfile": "shell",
    ]

    /// Tipo de visor por nombre (para elegir cuánto leer antes de tener los bytes).
    static func kind(forName name: String) -> FilePreviewKind {
        let ext = RemotePath.fileExtension(name)
        if markdownExtensions.contains(ext) { return .markdown }
        if htmlExtensions.contains(ext) { return .html }
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if name.lowercased().hasPrefix("dockerfile") { return .code(language: "shell") }
        return .code(language: languages[ext])
    }

    /// Tipo definitivo con los bytes: si "parece texto" pero no se puede decodificar
    /// como texto (ver `decodeText`), es binario.
    static func kind(forName name: String, data: Data) -> FilePreviewKind {
        let byName = kind(forName: name)
        if byName == .image { return .image }
        if byName == .pdf { return isPDF(data) ? .pdf : .binary }
        return looksBinary(data) ? .binary : byName
    }

    /// Firma `%PDF-` al principio (se tolera basura antes, como permiten los lectores).
    static func isPDF(_ data: Data) -> Bool {
        data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil
    }

    /// Heurística de binario sobre los primeros 8 KB: no se pueden decodificar como texto.
    static func looksBinary(_ data: Data) -> Bool {
        decodeText(data.prefix(sniffBytes)) == nil
    }

    /// Texto a mostrar: el decodificado o, si no lo es, UTF-8 con reemplazos (nunca falla).
    static func text(_ data: Data) -> String {
        decodeText(data) ?? String(decoding: data, as: UTF8.self)
    }

    /// Decodifica texto probando, en orden: BOM UTF-16, UTF-8 (tolera un carácter
    /// multibyte cortado al final del bloque leído) y Windows-1252 (o Latin-1), típico
    /// de HTML antiguo o exportado. `nil` si parece binario: NUL sin BOM UTF-16, o
    /// demasiados caracteres de control.
    static func decodeText(_ data: Data) -> String? {
        if let utf16 = decodeUTF16WithBOM(data) { return utf16 }
        let head = data.prefix(sniffBytes)
        if head.contains(0) { return nil }
        // Un corte a mitad de un carácter multibyte al final no lo hace binario.
        for trim in 0...3 where head.count >= trim {
            if String(data: head.dropLast(trim), encoding: .utf8) != nil {
                return String(decoding: data, as: UTF8.self)
            }
        }
        guard let legacy = String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1),
              !hasTooManyControlCharacters(String(legacy.prefix(sniffBytes)))
        else { return nil }
        return legacy
    }

    private static let sniffBytes = 8192

    /// UTF-16 solo con BOM explícito (sin BOM es indistinguible de un binario con NUL).
    private static func decodeUTF16WithBOM(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(2))
        guard bytes == [0xFF, 0xFE] || bytes == [0xFE, 0xFF] else { return nil }
        // Un bloque truncado puede acabar a mitad de una unidad de 16 bits.
        let even = data.count.isMultiple(of: 2) ? data : data.dropLast()
        guard let text = String(data: even, encoding: .utf16),
              !hasTooManyControlCharacters(String(text.prefix(sniffBytes / 2)))
        else { return nil }
        return text
    }

    /// Más de un 2 % de controles C0/C1 (salvo tab, saltos, form feed y ESC) = binario.
    private static func hasTooManyControlCharacters(_ text: String) -> Bool {
        let allowed: Set<UInt32> = [0x09, 0x0A, 0x0C, 0x0D, 0x1B]
        var total = 0
        var controls = 0
        for scalar in text.unicodeScalars {
            total += 1
            let value = scalar.value
            if (value < 0x20 || (0x7F...0x9F).contains(value)) && !allowed.contains(value) { controls += 1 }
        }
        return total > 0 && controls * 50 > total
    }
}
