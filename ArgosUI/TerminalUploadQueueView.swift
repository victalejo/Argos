//
//  TerminalUploadQueueView.swift
//  ArgosUI
//
//  Panel de la cola de subidas sobre el terminal (Mac e iPhone/iPad): progreso de la
//  tanda, archivo en curso y, si hay varios, la lista con cancelar/reintentar.
//

import SwiftUI

struct TerminalUploadQueueView: View {
    let model: TerminalUploadQueue
    /// Vista previa grande de la imagen en curso (se abre al pulsar la miniatura).
    @State private var isPreviewExpanded = false

    /// Filas visibles antes de desplazar la lista.
    private static let maxVisibleRows = 4
    private static let rowHeight: CGFloat = 30

    var body: some View {
        let queue = model.queue
        VStack(alignment: .leading, spacing: 8) {
            header(queue)
            if isPreviewExpanded, let thumbnail = featuredThumbnail(queue) {
                UploadThumbnailImage(thumbnail: thumbnail)
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .onTapGesture { isPreviewExpanded = false }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(Text("Ocultar vista previa"))
            }
            if queue.isBusy {
                ProgressView(value: queue.overallFraction)
                    .progressViewStyle(.linear)
            }
            if queue.items.count > 1 || queue.failedCount > 0 {
                itemList(queue)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Cabecera

    private func header(_ queue: UploadQueue) -> some View {
        HStack(spacing: 8) {
            headerIcon(queue)
            if let thumbnail = featuredThumbnail(queue) {
                Button { isPreviewExpanded.toggle() } label: {
                    UploadThumbnailImage(thumbnail: thumbnail).frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .help(Text("Ver la imagen que se sube"))
                .accessibilityLabel(Text(isPreviewExpanded ? "Ocultar vista previa" : "Ver la imagen que se sube"))
            }
            Text(headline(queue))
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if queue.isBusy {
                Text("\(queue.overallPercent) %")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Button("Cerrar") { model.dismissFinished() }
                    .buttonStyle(.borderless)
            }
        }
    }

    /// La imagen del archivo en curso o, si ya no hay nada pendiente, la del último.
    private func featuredThumbnail(_ queue: UploadQueue) -> UploadThumbnail? {
        guard let item = queue.current ?? queue.items.last else { return nil }
        return model.thumbnails[item.id]
    }

    @ViewBuilder
    private func headerIcon(_ queue: UploadQueue) -> some View {
        if queue.isBusy {
            ProgressView().controlSize(.small)
        } else if queue.failedCount > 0 {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private func headline(_ queue: UploadQueue) -> String {
        if let current = queue.current, let position = queue.currentPosition {
            if queue.batchCount > 1 {
                return String(localized: "Subiendo \(position) de \(queue.batchCount): \(current.name)")
            }
            return String(localized: "Subiendo «\(current.name)»")
        }
        if queue.isBusy {
            return String(localized: "Preparando la subida…")
        }
        if queue.failedCount > 0 {
            return String(localized: "Subidas con errores: \(queue.failedCount)")
        }
        return String(localized: "Subido al servidor: la ruta está en el prompt")
    }

    // MARK: - Lista

    private func itemList(_ queue: UploadQueue) -> some View {
        let visibleRows = min(queue.items.count, Self.maxVisibleRows)
        return ScrollView {
            VStack(spacing: 2) {
                ForEach(queue.items) { item in
                    TerminalUploadQueueRow(
                        item: item,
                        thumbnail: model.thumbnails[item.id],
                        onCancel: { model.cancel(item.id) },
                        onRetry: { model.retry(item.id) }
                    )
                    .frame(minHeight: Self.rowHeight)
                }
            }
        }
        .frame(maxHeight: CGFloat(visibleRows) * (Self.rowHeight + 2))
    }
}

/// Un archivo de la cola.
private struct TerminalUploadQueueRow: View {
    let item: UploadQueueItem
    let thumbnail: UploadThumbnail?
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 16)
            if let thumbnail {
                UploadThumbnailImage(thumbnail: thumbnail).frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(item.isFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            actions
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch item.state {
        case .waiting:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .uploading:
            ProgressView(value: item.fraction)
                .progressViewStyle(.circular)
                .controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var detail: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(item.totalBytes), countStyle: .file)
        switch item.state {
        case .waiting:
            return String(localized: "En cola · \(size)")
        case .uploading(let sent):
            let sentText = ByteCountFormatter.string(fromByteCount: Int64(sent), countStyle: .file)
            return String(localized: "\(sentText) de \(size)")
        case .done:
            return size
        case .failed(let message):
            return message
        }
    }

    @ViewBuilder
    private var actions: some View {
        if item.isPending {
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(Text("Cancelar"))
            .accessibilityLabel(Text("Cancelar"))
        } else if item.isFailed {
            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(Text("Reintentar"))
            .accessibilityLabel(Text("Reintentar"))
        }
    }
}

/// Miniatura recortada con esquinas redondeadas.
struct UploadThumbnailImage: View {
    let thumbnail: UploadThumbnail

    var body: some View {
        Image(decorative: thumbnail.image, scale: 1)
            .resizable()
            .aspectRatio(thumbnail.aspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }
}
