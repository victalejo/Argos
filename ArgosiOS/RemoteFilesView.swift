//
//  RemoteFilesView.swift
//  ArgosiOS
//
//  Explorador de archivos del proyecto (SFTP, solo lectura): una carpeta por pantalla,
//  como Archivos de iOS. Tocar un archivo lo previsualiza (código con resaltado,
//  Markdown, imágenes y PDF) y se puede compartir/guardar con la hoja de iOS.
//

import PDFKit
import SwiftUI

struct RemoteFilesView: View {
    let service: any SSHServicing
    /// Raíz del proyecto: SFTP no deja salir de aquí (`containedRealPath`).
    let root: String
    let path: String

    @State private var entries: [RemoteFileEntry]?
    @State private var errorMessage: String?
    @AppStorage("files.showHidden") private var showHidden = false

    private var visible: [RemoteFileEntry] {
        (entries ?? [])
            .filter { $0.isVisible(showHidden: showHidden) }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    var body: some View {
        Group {
            if let errorMessage {
                ContentUnavailableView {
                    Label("No se pudo abrir la carpeta", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Reintentar") { Task { await load() } }
                }
            } else if entries == nil {
                ProgressView()
            } else {
                List(visible) { entry in
                    // Enlace por destino (no por valor): esta pila ya usa navegación por
                    // `item` y mezclar ambas recrea la pantalla del proyecto.
                    NavigationLink {
                        FileDestination(service: service, root: root, entry: entry)
                    } label: {
                        FileRowView(entry: entry)
                    }
                }
                .overlay {
                    if visible.isEmpty {
                        ContentUnavailableView("Carpeta vacía", systemImage: "folder")
                    }
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle(path == root ? "Archivos" : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $showHidden) {
                    Label("Mostrar ocultos", systemImage: showHidden ? "eye" : "eye.slash")
                }
                .toggleStyle(.button)
            }
        }
        .task { if entries == nil { await load() } }
    }

    private func load() async {
        do {
            entries = try await service.listRemoteDirectory(path, root: root)
            errorMessage = nil
        } catch {
            errorMessage = error.userMessage
        }
    }
}

/// Carpeta o vista previa, según la entrada.
private struct FileDestination: View {
    let service: any SSHServicing
    let root: String
    let entry: RemoteFileEntry

    var body: some View {
        if entry.isDirectory {
            RemoteFilesView(service: service, root: root, path: entry.path)
        } else {
            FilePreviewScreen(service: service, root: root, entry: entry)
        }
    }
}

struct FileRowView: View {
    let entry: RemoteFileEntry

    var body: some View {
        let icon = FileIcon.icon(for: entry)
        HStack(spacing: 12) {
            Image(systemName: icon.symbol)
                .foregroundStyle(icon.tint.color)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if !entry.isDirectory, let size = entry.size {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if let modified = entry.modified {
            parts.append(modified.formatted(.relative(presentation: .named)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Vista previa

struct FilePreviewScreen: View {
    let service: any SSHServicing
    let root: String
    let entry: RemoteFileEntry

    private enum LoadState {
        case loading
        case loaded(RemoteFileContent, FilePreviewKind)
        case failed(String)
    }

    @State private var state: LoadState = .loading
    @State private var shareURL: URL?

    var body: some View {
        content
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let shareURL {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: shareURL) { Label("Compartir", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .task { await load() }
            .onDisappear { if let shareURL { try? FileManager.default.removeItem(at: shareURL.deletingLastPathComponent()) } }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView("No se pudo abrir", systemImage: "doc.questionmark", description: Text(message))
        case .loaded(let file, let kind):
            VStack(spacing: 0) {
                if file.isTruncated {
                    Label("Archivo grande: se muestra solo el principio.", systemImage: "scissors")
                        .font(.caption)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(.yellow.opacity(0.15))
                }
                preview(file, kind)
            }
        }
    }

    @ViewBuilder
    private func preview(_ file: RemoteFileContent, _ kind: FilePreviewKind) -> some View {
        switch kind {
        case .markdown:
            ScrollView {
                MarkdownText(text: String(decoding: file.data, as: UTF8.self), style: .document)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .code(let language):
            CodeView(text: String(decoding: file.data, as: UTF8.self), language: language)
        case .image:
            if let image = UIImage(data: file.data) {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image).resizable().scaledToFit().padding()
                }
            } else {
                ContentUnavailableView("Imagen no válida", systemImage: "photo")
            }
        case .pdf:
            PDFKitView(data: file.data)
        case .binary:
            ContentUnavailableView {
                Label("Archivo binario", systemImage: "doc.zipper")
            } description: {
                Text("No se puede previsualizar. Usa «Compartir» para abrirlo con otra app.")
            }
        }
    }

    private func load() async {
        let byName = FilePreview.kind(forName: entry.name)
        do {
            let file = try await service.readRemoteFile(entry.path, root: root, maxBytes: FilePreview.readLimit(for: byName))
            state = .loaded(file, FilePreview.kind(forName: entry.name, data: file.data))
            if !file.isTruncated { shareURL = try? temporaryCopy(of: file.data) }
        } catch {
            state = .failed(error.userMessage)
        }
    }

    /// Copia temporal con el nombre original para la hoja de compartir (se borra al salir).
    private func temporaryCopy(of data: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(entry.name)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}

/// Código con resaltado de sintaxis (mismo tokenizador que el Mac), con scroll en
/// ambos ejes para no partir líneas.
struct CodeView: View {
    let text: String
    let language: String?

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(CodeHighlight.attributed(text, language: language))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.secondarySystemBackground))
    }
}

enum CodeHighlight {
    /// Por encima de esto el texto se muestra plano (Text no escala bien con millones
    /// de atributos).
    static let maxHighlightedLength = 120_000

    static func attributed(_ text: String, language: String?) -> AttributedString {
        let result = NSMutableAttributedString(string: text)
        guard text.utf16.count <= maxHighlightedLength else { return AttributedString(result) }
        for token in SyntaxHighlighter.tokens(in: text, language: language) {
            result.addAttribute(.foregroundColor, value: color(for: token.kind), range: token.range)
        }
        return (try? AttributedString(result, including: \.uiKit)) ?? AttributedString(text)
    }

    private static func color(for kind: SyntaxHighlighter.Token.Kind) -> UIColor {
        switch kind {
        case .comment: return .systemGray
        case .string: return .systemRed
        case .number: return .systemIndigo
        case .keyword: return .systemPurple
        }
    }
}

private struct PDFKitView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}

extension FileIcon.Tint {
    var color: Color {
        switch self {
        case .blue: return .blue
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .mint: return .mint
        case .teal: return .teal
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .gray: return .gray
        case .brown: return .brown
        case .indigo: return .indigo
        }
    }
}
