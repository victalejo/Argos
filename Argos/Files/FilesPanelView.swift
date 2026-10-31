//
//  FilesPanelView.swift
//  Argos
//
//  Pestaña "Archivos" de un proyecto: árbol de carpetas (con iconos por tipo) a la
//  izquierda y visor a la derecha (Markdown renderizado, código resaltado, imágenes).
//  Solo lectura. ⌘P abre la búsqueda rápida de archivos.
//

import SwiftUI

struct FilesPanelView: View {
    @State private var model: FileBrowserModel
    @State private var isQuickOpenPresented = false

    init(root: String, service: any SSHServicing) {
        _model = State(initialValue: FileBrowserModel(root: root, service: service))
    }

    var body: some View {
        HSplitView {
            FileTreeView(model: model, onQuickOpen: { isQuickOpenPresented = true })
                .frame(minWidth: 180, idealWidth: 260, maxWidth: 420)
            FileViewer(model: model)
                .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await model.loadRootIfNeeded() }
        .sheet(isPresented: $isQuickOpenPresented) {
            QuickOpenSheet(model: model) { isQuickOpenPresented = false }
        }
        .background {
            // Atajo ⌘P sin ocupar sitio en la barra.
            Button("Buscar archivo") { isQuickOpenPresented = true }
                .keyboardShortcut("p", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Árbol

private struct FileTreeView: View {
    let model: FileBrowserModel
    let onQuickOpen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Button(action: onQuickOpen) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                    Text("Buscar archivo…")
                    Spacer(minLength: 0)
                    Text("⌘P").font(.caption2.monospaced())
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            Divider()
            if let error = model.directoryErrors[model.root] {
                ContentUnavailableView {
                    Label("No se pudo leer la carpeta", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Reintentar") { Task { await model.refresh() } }
                }
            } else if model.loadingDirectories.contains(model.root) && model.rows.isEmpty {
                ProgressView("Cargando archivos…")
                    .font(.callout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.rows.isEmpty {
                ContentUnavailableView {
                    Label("Carpeta vacía", systemImage: "folder")
                } description: {
                    Text(model.showHidden ? "No hay archivos en esta carpeta." : "No hay archivos visibles. Puedes mostrar los archivos ocultos con el botón del ojo.")
                }
            } else {
                List(model.rows) { row in
                    FileTreeRowView(row: row, model: model)
                        .listRowInsets(EdgeInsets(top: 1, leading: 6 + CGFloat(row.depth) * 14, bottom: 1, trailing: 6))
                }
                .listStyle(.sidebar)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill").foregroundStyle(.tint)
            Text(model.rootName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.root)
            Spacer()
            Toggle(isOn: Binding(get: { model.showHidden }, set: { model.showHidden = $0 })) {
                Image(systemName: model.showHidden ? "eye" : "eye.slash")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help(model.showHidden ? "Ocultar archivos ocultos y carpetas generadas" : "Mostrar ocultos, .git, node_modules…")
            .accessibilityLabel("Mostrar archivos ocultos")
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Recargar (por si Claude cambió archivos)")
            .accessibilityLabel("Recargar archivos")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
    }
}

private struct FileTreeRowView: View {
    let row: FileTreeRow
    let model: FileBrowserModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var entry: RemoteFileEntry { row.entry }
    private var isExpanded: Bool { model.expanded.contains(entry.path) }
    private var isSelected: Bool {
        switch model.preview {
        case .loading(let current), .loaded(let current, _, _), .failed(let current, _):
            return current.path == entry.path
        case .empty:
            return false
        }
    }

    var body: some View {
        let icon = FileIcon.icon(for: entry)
        Button {
            Task {
                if entry.isDirectory { await model.toggle(entry) } else { await model.open(entry) }
            }
        } label: {
            HStack(spacing: 5) {
                Group {
                    if entry.isDirectory {
                        if model.loadingDirectories.contains(entry.path) {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        }
                    }
                }
                .frame(width: 10)
                Image(systemName: icon.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(icon.tint.color)
                    .frame(width: 18)
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(entry.isHidden ? .secondary : .primary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 4)
            .background(isSelected ? Color.accentColor.opacity(0.14) : (isHovering ? Color.primary.opacity(0.045) : .clear), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(RemotePath.relative(entry.path, to: model.root))
        .accessibilityLabel(entry.isDirectory ? "Carpeta \(entry.name), \(isExpanded ? "expandida" : "contraída")" : entry.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovering)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isExpanded)
    }
}

// MARK: - Visor

private struct FileViewer: View {
    let model: FileBrowserModel
    @State private var showSource = false
    @State private var settings = TerminalSettings.shared

    var body: some View {
        switch model.preview {
        case .empty:
            VStack(spacing: 15) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 76, height: 76)
                    .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 22))
                Text("Explora tu proyecto").font(.title3.weight(.semibold))
                Text("Elige un archivo del explorador o pulsa ⌘P para buscarlo por nombre.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 330)
                Label("Vista de solo lectura", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading(let entry):
            VStack(spacing: 0) {
                FileViewerHeader(entry: entry, root: model.root, content: nil, showSource: nil)
                Divider()
                ProgressView("Abriendo \(entry.name)…")
                    .font(.callout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .failed(let entry, let message):
            VStack(spacing: 0) {
                FileViewerHeader(entry: entry, root: model.root, content: nil, showSource: nil)
                Divider()
                ContentUnavailableView {
                    Label("No se pudo abrir", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Reintentar") { Task { await model.open(entry) } }
                }
            }
        case .loaded(let entry, let content, let kind):
            VStack(spacing: 0) {
                FileViewerHeader(
                    entry: entry,
                    root: model.root,
                    content: content,
                    showSource: kind == .markdown ? $showSource : nil
                )
                Divider()
                body(for: kind, content: content)
            }
        }
    }

    @ViewBuilder
    private func body(for kind: FilePreviewKind, content: RemoteFileContent) -> some View {
        switch kind {
        case .markdown where !showSource:
            ScrollView {
                SafeMarkdownView(text: String(decoding: content.data, as: UTF8.self))
                    .textSelection(.enabled)
                    .padding(24)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
        case .markdown:
            CodeTextView(text: String(decoding: content.data, as: UTF8.self), language: nil, fontSize: codeFontSize)
        case .code(let language):
            CodeTextView(text: String(decoding: content.data, as: UTF8.self), language: language, fontSize: codeFontSize)
        case .image:
            if let image = NSImage(data: content.data) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                        .padding(20)
                }
            } else {
                ContentUnavailableView("Imagen no compatible", systemImage: "photo.badge.exclamationmark")
            }
        case .binary:
            ContentUnavailableView {
                Label("Archivo binario", systemImage: "doc.zipper")
            } description: {
                Text("No se puede mostrar como texto (\(ResourceFormat.kilobytes(Int(content.size / 1024)))).")
            }
        }
    }

    /// Un poco más pequeño que el terminal: en el visor se ve más código a la vez.
    private var codeFontSize: CGFloat { max(10, CGFloat(settings.fontSize) - 0.5) }
}

private struct FileViewerHeader: View {
    let entry: RemoteFileEntry
    let root: String
    let content: RemoteFileContent?
    let showSource: Binding<Bool>?

    var body: some View {
        let icon = FileIcon.icon(for: entry)
        HStack(spacing: 8) {
            Image(systemName: icon.symbol).foregroundStyle(icon.tint.color)
            Text(RemotePath.relative(entry.path, to: root))
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            if content?.isTruncated == true {
                Label("Truncado", systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("El archivo es grande: solo se muestra el principio.")
            }
            Spacer()
            if let content {
                Text(metadata(content))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let showSource {
                Picker("", selection: showSource) {
                    Text("Vista").tag(false)
                    Text("Fuente").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.path, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copiar la ruta en el servidor")
            .accessibilityLabel("Copiar ruta del archivo")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func metadata(_ content: RemoteFileContent) -> String {
        let size = content.size < 1024 ? "\(content.size) B" : ResourceFormat.kilobytes(Int(content.size / 1024))
        guard let modified = content.modified else { return size }
        return "\(size) · \(modified.formatted(.relative(presentation: .named)))"
    }
}

// MARK: - Búsqueda rápida (⌘P)

private struct QuickOpenSheet: View {
    let model: FileBrowserModel
    let onClose: () -> Void

    @State private var query = ""
    @State private var selection: String?
    @FocusState private var isFieldFocused: Bool

    private var results: [String] {
        FileBrowserModel.matches(query, in: model.fileIndex ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar archivo en \(model.rootName)…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isFieldFocused)
                    .onSubmit { open(selection ?? results.first) }
                    .accessibilityLabel("Buscar archivo por nombre")
                if model.fileIndex == nil { ProgressView().controlSize(.small) }
            }
            .padding(18)
            Divider()
            List(results, id: \.self, selection: $selection) { path in
                let name = (path as NSString).lastPathComponent
                let icon = FileIcon.file(named: name)
                HStack(spacing: 8) {
                    Image(systemName: icon.symbol).foregroundStyle(icon.tint.color).frame(width: 18)
                    Text(name).fontWeight(.medium)
                    Text((path as NSString).deletingLastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .tag(path)
            }
            .listStyle(.plain)
            .overlay {
                if results.isEmpty && model.fileIndex != nil {
                    ContentUnavailableView {
                        Label("Sin archivos disponibles", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text(query.isEmpty ? "No hay archivos disponibles para esta búsqueda." : "Prueba con otro nombre o parte de la ruta.")
                    }
                }
            }
            .onChange(of: selection) { _, path in
                // Clic con el ratón abre directamente; con las flechas solo se selecciona
                // (⏎ abre). OJO: `clickCount` solo es válido en eventos de ratón.
                guard let path, let event = NSApp.currentEvent,
                      event.type == .leftMouseDown || event.type == .leftMouseUp else { return }
                open(path)
            }
            Divider()
            HStack(spacing: 8) {
                Text("↑↓ seleccionar · ⏎ abrir")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(results.count) resultados")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button("Cerrar", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .frame(width: 600, height: 420)
        .task {
            isFieldFocused = true
            await model.loadIndexIfNeeded()
        }
        .onExitCommand(perform: onClose)
        .onChange(of: query) { _, _ in selection = nil }
    }

    private func open(_ path: String?) {
        guard let path else { return }
        onClose()
        Task { await model.open(relativePath: path) }
    }
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
