//
//  TerminalInputActions.swift
//  ArgosiOS
//
//  Lo que el terminal del iPhone/iPad hace con texto, fotos y archivos:
//  · «Seleccionar texto»: hoja con el panel y su historial (`tmux capture-pane`) para
//    seleccionar con las asas de iOS, copiar o compartir.
//  · Adjuntar fotos (fototeca) o archivos (Archivos): se suben a una ruta privada del
//    servidor y su ruta se escribe en el prompt (como al soltarlos en el Mac).
//  · Aviso breve sobre el terminal: «Copiado», «Subiendo…», errores.
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct TerminalInputActions: ViewModifier {
    let controller: TouchTerminalController?
    @Binding var isPickingPhotos: Bool
    @Binding var isPickingFiles: Bool
    @Binding var isShowingText: Bool
    @State private var photoItems: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let notice = controller?.notice {
                    NoticeBanner(notice: notice)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: controller?.notice)
            .photosPicker(isPresented: $isPickingPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .images)
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                Task { await attachPhotos(items) }
            }
            .fileImporter(isPresented: $isPickingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                attachFiles(result)
            }
            .sheet(isPresented: $isShowingText) {
                if let controller {
                    TerminalTextSheet(controller: controller)
                }
            }
    }

    private func attachPhotos(_ items: [PhotosPickerItem]) async {
        guard let controller else { return }
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension
                controller.attach(data: data, fileName: TerminalAttachment.photoFileName(fileExtension: ext))
            } catch {
                controller.show(.failed("No se pudo leer la foto: \(error.userMessage)"))
            }
        }
    }

    private func attachFiles(_ result: Result<[URL], Error>) {
        guard let controller else { return }
        do {
            for url in try result.get() {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= TerminalAttachment.maxBytes else {
                    controller.show(.failed(TerminalAttachment.tooLargeMessage(fileName: url.lastPathComponent)))
                    continue
                }
                controller.attach(data: try Data(contentsOf: url), fileName: url.lastPathComponent)
            }
        } catch {
            controller.show(.failed("No se pudo leer el archivo: \(error.userMessage)"))
        }
    }
}

private struct NoticeBanner: View {
    let notice: TerminalNotice

    var body: some View {
        Label(notice.text, systemImage: notice.symbolName)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
            .padding(.horizontal)
    }
}

/// Texto del panel con su historial, seleccionable con las herramientas de iOS.
struct TerminalTextSheet: View {
    let controller: TouchTerminalController
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let text {
                    SelectableTextView(text: text)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("No se pudo leer el terminal", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Reintentar") { Task { await load() } }
                    }
                } else {
                    ProgressView("Leyendo el terminal…")
                }
            }
            .background(Color(white: 0.07))
            .navigationTitle("Seleccionar texto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(white: 0.11), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
                if let text {
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Más", systemImage: "ellipsis.circle") {
                            Button("Copiar todo", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = text
                                dismiss()
                            }
                            ShareLink(item: text) { Label("Compartir", systemImage: "square.and.arrow.up") }
                        }
                    }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        errorMessage = nil
        do {
            text = try await controller.capturedText()
        } catch {
            errorMessage = error.userMessage
        }
    }
}

/// `UITextView` de solo lectura (selección nativa con asas y menú Copiar) que abre al
/// final, donde está lo más reciente.
private struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.backgroundColor = UIColor(white: 0.07, alpha: 1)
        view.textColor = UIColor(white: 0.92, alpha: 1)
        view.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 24, right: 8)
        view.dataDetectorTypes = [.link]
        view.text = text
        DispatchQueue.main.async {
            let end = NSRange(location: (view.text as NSString).length, length: 0)
            view.scrollRangeToVisible(end)
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
