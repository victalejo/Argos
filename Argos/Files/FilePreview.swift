//
//  FilePreview.swift
//  Argos
//
//  Qué visor usar para un archivo (Markdown renderizado, código, imagen, binario) y
//  límites de tamaño. Lógica pura: decide a partir del nombre y de los bytes leídos.
//

import Foundation

enum FilePreviewKind: Equatable, Sendable {
    case markdown
    case code(language: String?)
    case image
    case binary
}

enum FilePreview {
    /// Por encima de esto solo se lee el principio del archivo (visor en modo "truncado").
    static let maxTextBytes: UInt64 = 2 * 1024 * 1024
    /// Las imágenes se muestran enteras hasta este tamaño.
    static let maxImageBytes: UInt64 = 20 * 1024 * 1024

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "ico", "tiff", "avif"]
    private static let markdownExtensions: Set<String> = ["md", "mdx", "markdown"]

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
        if imageExtensions.contains(ext) { return .image }
        if name.lowercased().hasPrefix("dockerfile") { return .code(language: "shell") }
        return .code(language: languages[ext])
    }

    /// Tipo definitivo con los bytes: si "parece texto" pero tiene NUL o no es UTF-8,
    /// es binario.
    static func kind(forName name: String, data: Data) -> FilePreviewKind {
        let byName = kind(forName: name)
        if byName == .image { return .image }
        return looksBinary(data) ? .binary : byName
    }

    /// Heurística de binario: un byte NUL en los primeros 8 KB, o UTF-8 inválido.
    static func looksBinary(_ data: Data) -> Bool {
        let head = data.prefix(8192)
        if head.contains(0) { return true }
        // Un corte a mitad de un carácter multibyte al final no lo hace binario.
        for trim in 0...3 where head.count >= trim {
            if String(data: head.dropLast(trim), encoding: .utf8) != nil { return false }
        }
        return true
    }
}
