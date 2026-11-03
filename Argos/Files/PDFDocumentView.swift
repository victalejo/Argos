//
//  PDFDocumentView.swift
//  Argos
//
//  Visor de PDF (PDFKit) para el explorador de archivos: desplazamiento continuo,
//  ajuste al ancho y texto seleccionable. Solo lectura.
//
//  El PDF viene del servidor (no es de fiar): sus enlaces NO se abren solos. Solo
//  http/https/mailto y tras confirmar mostrando la URL (`SafeLinkPolicy`), igual que
//  en el visor de Markdown; los saltos a otros PDF se ignoran.
//

import PDFKit
import SwiftUI

struct PDFDocumentView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .underPageBackgroundColor
        view.document = document
        view.delegate = context.coordinator
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
            view.autoScales = true
        }
    }
}

extension PDFDocumentView {
    @MainActor
    final class Coordinator: NSObject, PDFViewDelegate {
        /// Sustituye la apertura automática de PDFKit (que abriría `file://` o
        /// cualquier esquema) por la política segura.
        func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
            guard SafeLinkPolicy.isAllowed(url) else {
                Log.store.notice("Enlace de PDF bloqueado (esquema no permitido): \(url.scheme ?? "-", privacy: .public)")
                return
            }
            if SafeLinkPolicy.confirm(url) { NSWorkspace.shared.open(url) }
        }

        /// Un «ir a otro PDF» no abre nada fuera del visor.
        func pdfViewOpenPDF(_ sender: PDFView, forRemoteGoToAction action: PDFActionRemoteGoTo) {}
    }
}
