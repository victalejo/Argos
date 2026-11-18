//
//  QuickLookDocumentView.swift
//  Argos
//
//  Visor de hojas de cálculo (Excel, Numbers) con Vista Rápida del sistema: hojas,
//  formato y pestañas sin dependencias propias. El contenido se escribe en un temporal
//  (`QuickLookTempFile`) que se borra al cambiar de archivo o cerrar el visor.
//

import Quartz
import SwiftUI

struct QuickLookDocumentView: NSViewRepresentable {
    let data: Data
    let name: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        context.coordinator.show(data: data, name: name, in: view)
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        context.coordinator.show(data: data, name: name, in: view)
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.previewItem = nil
        view.close()
        coordinator.clear()
    }

    @MainActor
    final class Coordinator {
        private var file: QuickLookTempFile?
        private var shown: (data: Data, name: String)?

        func show(data: Data, name: String, in view: QLPreviewView) {
            if let shown, shown.name == name, shown.data == data { return }
            clear()
            do {
                let file = try QuickLookTempFile(data: data, name: name)
                self.file = file
                shown = (data, name)
                view.previewItem = file.url as NSURL
            } catch {
                Log.store.error("Vista Rápida: no se pudo preparar \(name, privacy: .public): \(String(describing: error), privacy: .public)")
                view.previewItem = nil
            }
        }

        func clear() {
            file?.remove()
            file = nil
            shown = nil
        }
    }
}
