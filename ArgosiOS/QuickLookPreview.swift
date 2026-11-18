//
//  QuickLookPreview.swift
//  ArgosiOS
//
//  Hojas de cálculo (Excel, Numbers) en el explorador con Vista Rápida del sistema.
//  El contenido se escribe en un temporal (`QuickLookTempFile`) que se borra al
//  cambiar de archivo o cerrar el visor.
//

import QuickLook
import SwiftUI

struct QuickLookPreview: UIViewControllerRepresentable {
    let data: Data
    let name: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        context.coordinator.show(data: data, name: name, in: controller)
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.show(data: data, name: name, in: controller)
    }

    static func dismantleUIViewController(_ controller: QLPreviewController, coordinator: Coordinator) {
        coordinator.clear()
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency QLPreviewControllerDataSource {
        private var file: QuickLookTempFile?
        private var shown: (data: Data, name: String)?

        func show(data: Data, name: String, in controller: QLPreviewController) {
            if let shown, shown.name == name, shown.data == data { return }
            clear()
            do {
                file = try QuickLookTempFile(data: data, name: name)
                shown = (data, name)
            } catch {
                Log.store.error("Vista Rápida: no se pudo preparar \(name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            controller.reloadData()
        }

        func clear() {
            file?.remove()
            file = nil
            shown = nil
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            file == nil ? 0 : 1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            (file?.url ?? URL(fileURLWithPath: "/dev/null")) as NSURL
        }
    }
}
