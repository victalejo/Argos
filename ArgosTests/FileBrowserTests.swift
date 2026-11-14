//
//  FileBrowserTests.swift
//  ArgosTests
//
//  Explorador de archivos: tipo de entrada desde st_mode, orden, ocultos, contención
//  de rutas, iconos por carpeta/archivo, visor y resaltado de sintaxis.
//

import Foundation
import Testing
@testable import Argos

@Suite("Explorador de archivos")
struct FileBrowserTests {

    // MARK: - Entradas

    @Test("Tipo desde st_mode: carpeta, symlink, archivo")
    func kindFromMode() {
        #expect(RemoteFileEntry(name: "src", parent: "/p", permissions: 0o040755, size: nil, modified: nil).kind == .directory)
        #expect(RemoteFileEntry(name: "l", parent: "/p", permissions: 0o120777, size: nil, modified: nil).kind == .symlink)
        #expect(RemoteFileEntry(name: "a.ts", parent: "/p/", permissions: 0o100644, size: 3, modified: nil).path == "/p/a.ts")
    }

    @Test("Orden: carpetas primero y orden natural")
    func sorting() {
        let entries = [
            RemoteFileEntry(name: "file10.txt", path: "/p/file10.txt", kind: .file),
            RemoteFileEntry(name: "zeta", path: "/p/zeta", kind: .directory),
            RemoteFileEntry(name: "file2.txt", path: "/p/file2.txt", kind: .file),
            RemoteFileEntry(name: "Alpha", path: "/p/Alpha", kind: .directory),
        ]
        #expect(RemoteFileEntry.sorted(entries).map(\.name) == ["Alpha", "zeta", "file2.txt", "file10.txt"])
    }

    @Test("Ocultos y carpetas pesadas solo con 'mostrar ocultos'")
    func visibility() {
        let git = RemoteFileEntry(name: ".git", path: "/p/.git", kind: .directory)
        let modules = RemoteFileEntry(name: "node_modules", path: "/p/node_modules", kind: .directory)
        let env = RemoteFileEntry(name: ".env", path: "/p/.env", kind: .file)
        let src = RemoteFileEntry(name: "src", path: "/p/src", kind: .directory)
        let buildFile = RemoteFileEntry(name: "build", path: "/p/build", kind: .file)
        #expect(!git.isVisible(showHidden: false) && git.isVisible(showHidden: true))
        #expect(!modules.isVisible(showHidden: false))
        #expect(!env.isVisible(showHidden: false))
        #expect(src.isVisible(showHidden: false))
        #expect(buildFile.isVisible(showHidden: false), "un ARCHIVO llamado build no se oculta")
    }

    @Test("Contención por componentes (app-old no está dentro de app)")
    func containment() {
        #expect(RemotePath.isInside("/srv/app/src/a.ts", root: "/srv/app"))
        #expect(RemotePath.isInside("/srv/app", root: "/srv/app/"))
        #expect(!RemotePath.isInside("/srv/app-old/a.ts", root: "/srv/app"))
        #expect(!RemotePath.isInside("/etc/passwd", root: "/srv/app"))
        #expect(RemotePath.relative("/srv/app/src/a.ts", to: "/srv/app") == "src/a.ts")
    }

    // MARK: - Iconos

    @Test("Carpetas comunes con icono propio; el resto genérico")
    func folderIcons() {
        #expect(FileIcon.folder(named: "src").symbol == "curlybraces")
        #expect(FileIcon.folder(named: "docs").symbol == "book.closed.fill")
        #expect(FileIcon.folder(named: "tests").symbol == "checkmark.seal.fill")
        #expect(FileIcon.folder(named: ".github").symbol == "arrow.triangle.branch")
        #expect(FileIcon.folder(named: "node_modules").symbol == "shippingbox.fill")
        #expect(FileIcon.folder(named: "Components").symbol == "square.stack.3d.up.fill")
        #expect(FileIcon.folder(named: "mi-carpeta") == FileIcon.genericFolder)
    }

    @Test("Archivos por nombre exacto y extensión")
    func fileIcons() {
        #expect(FileIcon.file(named: "package.json").symbol == "shippingbox.fill")
        #expect(FileIcon.file(named: "README.md").symbol == "book.fill")
        #expect(FileIcon.file(named: "notas.md").symbol == "doc.richtext.fill")
        #expect(FileIcon.file(named: ".env.local").symbol == "key.fill")
        #expect(FileIcon.file(named: "Dockerfile.prod").symbol == "shippingbox.circle.fill")
        #expect(FileIcon.file(named: "App.swift").symbol == "swift")
        #expect(FileIcon.file(named: "sin-extension") == FileIcon.genericFile)
    }

    // MARK: - Visor

    @Test("Visor por nombre: Markdown, imagen, código con lenguaje")
    func previewKind() {
        #expect(FilePreview.kind(forName: "README.md") == .markdown)
        #expect(FilePreview.kind(forName: "logo.PNG") == .image)
        #expect(FilePreview.kind(forName: "page.tsx") == .code(language: "typescript"))
        #expect(FilePreview.kind(forName: "Dockerfile") == .code(language: "shell"))
        #expect(FilePreview.kind(forName: "datos.xyz") == .code(language: nil))
        #expect(FilePreview.kind(forName: "informe.HTML") == .html)
        #expect(FilePreview.kind(forName: "viejo.htm") == .html)
    }

    @Test("Binario: NUL o UTF-8 inválido; texto con multibyte cortado no lo es")
    func binaryDetection() {
        #expect(FilePreview.looksBinary(Data([0x48, 0x00, 0x49])))
        #expect(FilePreview.looksBinary(Data([0x80, 0x81, 0x8D, 0x8F, 0x90, 0x9D, 0x01, 0x02])))
        #expect(!FilePreview.looksBinary(Data("hola mundo ñ".utf8)))
        // "acci" + primer byte de "ó": multibyte cortado al final del bloque leído.
        #expect(!FilePreview.looksBinary(Data("acci".utf8) + Data([0xC3])))
        #expect(FilePreview.kind(forName: "a.txt", data: Data([0, 1, 2])) == .binary)
        #expect(FilePreview.kind(forName: "foto.png", data: Data([0, 1, 2])) == .image)
    }

    @Test("Texto Windows-1252/Latin-1 (HTML antiguo) se decodifica en vez de tratarse como binario")
    func legacyEncodingText() throws {
        let html = try #require("<html><body>Página de acción €</body></html>".data(using: .windowsCP1252))
        #expect(!FilePreview.looksBinary(html))
        #expect(FilePreview.kind(forName: "host.html", data: html) == .html)
        #expect(FilePreview.text(html).contains("Página de acción €"))
    }

    @Test("UTF-16 con BOM es texto (aunque tenga NUL); sin BOM, binario")
    func utf16Text() throws {
        let withBOM = try #require("<p>hola ñ</p>".data(using: .utf16))
        #expect(FilePreview.kind(forName: "a.html", data: withBOM) == .html)
        #expect(FilePreview.text(withBOM) == "<p>hola ñ</p>")
        // Bloque truncado a mitad de una unidad de 16 bits.
        #expect(FilePreview.text(withBOM.dropLast()).hasPrefix("<p>hola"))
        let withoutBOM = try #require("<p>hola</p>".data(using: .utf16LittleEndian))
        #expect(FilePreview.looksBinary(withoutBOM))
    }

    @Test("UTF-8 válido se decodifica tal cual")
    func utf8Text() {
        #expect(FilePreview.text(Data("<h1>Título</h1>".utf8)) == "<h1>Título</h1>")
        #expect(FilePreview.decodeText(Data([0x00, 0x41])) == nil)
    }

    // MARK: - Resaltado

    private func kinds(_ text: String, _ language: String) -> [(SyntaxHighlighter.Token.Kind, String)] {
        let ns = text as NSString
        return SyntaxHighlighter.tokens(in: text, language: language).map { ($0.kind, ns.substring(with: $0.range)) }
    }

    @Test("Swift: palabras clave, cadenas con escapes, comentarios y números")
    func highlightSwift() {
        let tokens = kinds("let x = \"a\\\"b\" // fin\nreturn 42 /* b */", "swift")
        #expect(tokens.contains { $0 == (.keyword, "let") })
        #expect(tokens.contains { $0 == (.string, "\"a\\\"b\"") })
        #expect(tokens.contains { $0 == (.comment, "// fin") })
        #expect(tokens.contains { $0 == (.keyword, "return") })
        #expect(tokens.contains { $0 == (.number, "42") })
        #expect(tokens.contains { $0 == (.comment, "/* b */") })
    }

    @Test("Una palabra clave dentro de una cadena o comentario no se resalta aparte")
    func keywordInsideString() {
        let tokens = kinds("x = \"return\" # if", "python")
        #expect(!tokens.contains { $0.0 == .keyword })
        #expect(tokens.count == 2)
    }

    @Test("Identificadores con dígitos no son números; lenguaje desconocido no resalta")
    func identifiersAndUnknown() {
        #expect(!kinds("v2 = x3", "javascript").contains { $0.0 == .number })
        #expect(SyntaxHighlighter.tokens(in: "let x = 1", language: nil).isEmpty)
    }

    @Test("Cadena sin cerrar no se come las líneas siguientes")
    func unterminatedString() {
        let tokens = kinds("a = 'abc\nreturn b", "python")
        #expect(tokens.contains { $0 == (.keyword, "return") })
    }

    // MARK: - Enlaces en Markdown

    @Test("Solo se pueden abrir enlaces http/https/mailto")
    func linkPolicy() throws {
        #expect(SafeLinkPolicy.isAllowed(try #require(URL(string: "https://nextjs.org"))))
        #expect(SafeLinkPolicy.isAllowed(try #require(URL(string: "mailto:a@b.co"))))
        #expect(!SafeLinkPolicy.isAllowed(try #require(URL(string: "file:///etc/passwd"))))
        #expect(!SafeLinkPolicy.isAllowed(try #require(URL(string: "x-apple-systempreferences:com.apple"))))
        #expect(!SafeLinkPolicy.isAllowed(try #require(URL(string: "javascript:alert(1)"))))
        #expect(!SafeLinkPolicy.isAllowed(try #require(URL(string: "docs/README.md"))))
    }
}

@Suite("Visor de PDF y descargas")
@MainActor
struct FilePDFAndDownloadTests {
    @Test("Los .pdf se previsualizan como PDF y leen hasta su propio límite")
    func pdfKindByName() {
        #expect(FilePreview.kind(forName: "Cotizacion.PDF") == .pdf)
        #expect(FilePreview.readLimit(for: .pdf) == FilePreview.maxPDFBytes)
        #expect(FilePreview.readLimit(for: .image) == FilePreview.maxImageBytes)
        #expect(FilePreview.readLimit(for: .markdown) == FilePreview.maxTextBytes)
    }

    @Test("Con bytes: firma %PDF- = PDF; sin ella = binario")
    func pdfKindByContent() {
        #expect(FilePreview.kind(forName: "a.pdf", data: Data("%PDF-1.7\n\u{0}\u{1}".utf8)) == .pdf)
        #expect(FilePreview.kind(forName: "a.pdf", data: Data("basura\n%PDF-1.4".utf8)) == .pdf)
        #expect(FilePreview.kind(forName: "a.pdf", data: Data([0, 1, 2, 3])) == .binary)
    }

    @Test("Descargar al Mac copia el archivo entero y deja el estado en «guardado»")
    func downloadSavesFile() async throws {
        let mock = MockSSHService()
        let bytes = Data("%PDF-1.7 contenido".utf8)
        mock.remoteFiles["/srv/p/doc.pdf"] = bytes
        let model = FileBrowserModel(root: "/srv/p", service: mock)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("argos-dl-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: destination) }

        await model.downloadToMac(RemoteFileEntry(name: "doc.pdf", path: "/srv/p/doc.pdf", kind: .file), to: destination)

        #expect(try Data(contentsOf: destination) == bytes)
        #expect(model.downloadStatus == .saved(destination))
    }
}
